extends Node
## Headless movement + generation verification. Run with:
##   godot --headless --path . res://scenes/main.tscn --quit-after 6000 -- movetest

var fails := 0
var total := 0


func check(cname: String, ok: bool, info := "") -> void:
	total += 1
	if ok:
		print("  [ok] " + cname)
	else:
		fails += 1
		print("  [FAIL] " + cname + (("   :: " + info) if info != "" else ""))


func sim(frames: int) -> void:
	for i in range(frames):
		await get_tree().physics_frame


func hspeed(p) -> float:
	return Vector3(p.velocity.x, 0, p.velocity.z).length()


func transform_motion(node: Node3D, reference: Transform3D) -> float:
	# Position catches gait bob/translation while two basis axes catch rotations
	# even when Euler angles cross +/-PI during a stroke.
	var current := node.global_transform
	return current.origin.distance_to(reference.origin) \
		+ current.basis.y.normalized().distance_to(reference.basis.y.normalized()) \
		+ current.basis.z.normalized().distance_to(reference.basis.z.normalized())


func rig_limb_endpoints(r: MonkeyRig) -> Array[Vector3]:
	return [
		r.el_l.to_global(Vector3(0, -r.ARM_B, 0)),
		r.el_r.to_global(Vector3(0, -r.ARM_B, 0)),
		r.kn_l.to_global(Vector3(0, -r.LEG_B, 0)),
		r.kn_r.to_global(Vector3(0, -r.LEG_B, 0)),
	]


func reset(p, w) -> void:
	p.ti.dir = Vector2.ZERO
	p.ti.sprint = false
	p.ti.crouch_held = false
	p.ti.grab = false
	p.ti.reel = 0.0
	p.ti.jump_held = false
	p.global_position = w.spawn_point()
	p.velocity = Vector3.ZERO
	p.state = p.S.AIR
	await sim(45)


func run(main) -> void:
	print("MOVETEST begin (seed=%d)" % Gen.world_seed)
	var w = main.world
	var p = w.local_player
	p.test_mode = true

	# 1 — generation is deterministic (same layout twice)
	var a := Gen.chunk_layout(2, 5)
	var b := Gen.chunk_layout(2, 5)
	var det: bool = a.trees.size() == b.trees.size() and a.bananas.size() == b.bananas.size()
	if det and a.trees.size() > 0:
		det = a.trees[0].pos == b.trees[0].pos and a.trees[0].vines.size() == b.trees[0].vines.size()
	check("chunk_layout deterministic", det)

	# 2 — terrain heights sane everywhere sampled. Ridged mountain ranges may
	# legitimately reach ~80 m; the bound only guards against NaN/runaway noise.
	var ok_h := true
	for i in range(120):
		var h := Gen.height(i * 13.7 - 800.0, i * 7.3 - 400.0)
		if is_nan(h) or absf(h) > 120.0:
			ok_h = false
	check("terrain heights finite", ok_h)

	# 3 — world warmed chunks around spawn
	check("chunks warmed", w.chunks.size() >= 25, "have %d" % w.chunks.size())

	# 4 — vines registered, hanging above ground
	var vine_ok := true
	var n_vines := 0
	for id in Gen.vines:
		var v: Dictionary = Gen.vines[id]
		n_vines += 1
		if v.anchor.y - float(v.len) < Gen.height(v.anchor.x, v.anchor.z) + 1.0:
			vine_ok = false
	check("vines registered + off ground", n_vines >= 15 and vine_ok, "n=%d" % n_vines)

	# 5 — spawn, fall, land on terrain
	await reset(p, w)
	check("falls and lands", p.is_on_floor() and absf(p.global_position.y - Gen.height(p.global_position.x, p.global_position.z)) < 3.0,
		"y=%.1f state=%d" % [p.global_position.y, p.state])

	# 6 — run
	p.ti.dir = Vector2(0, -1)
	await sim(75)
	check("run speed", hspeed(p) >= 5.5, "%.1f" % hspeed(p))

	# 7 — sprint is faster
	p.ti.sprint = true
	await sim(90)
	check("sprint faster", hspeed(p) >= 9.5, "%.1f" % hspeed(p))

	# 8 — jump: rises, variable height, lands
	await reset(p, w)
	p.ti.jump_held = true
	p.ti.jump_just = true
	await sim(3)
	var airborne: bool = (not p.is_on_floor()) and p.velocity.y > 2.0
	var y0: float = p.global_position.y
	var peak := y0
	for i in range(90):
		await get_tree().physics_frame
		peak = maxf(peak, p.global_position.y)
		if p.is_on_floor():
			break
	p.ti.jump_held = false
	check("jump rises and lands", airborne and p.is_on_floor() and (peak - y0) > 0.8 and (peak - y0) < 4.0, "dy=%.2f" % (peak - y0))

	# 9 — double jump mid-air
	p.ti.jump_held = true
	p.ti.jump_just = true
	await sim(20)
	p.ti.jump_just = true
	await sim(2)
	check("double jump", p.velocity.y > 5.0 and p.jumps_used == 2, "vy=%.1f jumps=%d" % [p.velocity.y, p.jumps_used])
	p.ti.jump_held = false
	await sim(120)

	# 10 — slide keeps momentum
	await reset(p, w)
	p.ti.dir = Vector2(0, -1)
	p.ti.sprint = true
	await sim(80)
	var pre := hspeed(p)
	p.ti.crouch_just = true
	p.ti.crouch_held = true
	await sim(3)
	check("slide entered w/ momentum", p.state == p.S.SLIDE and hspeed(p) >= pre * 0.9 and pre > 8.0,
		"pre=%.1f now=%.1f state=%d" % [pre, hspeed(p), p.state])
	p.ti.crouch_held = false
	p.ti.sprint = false
	p.ti.dir = Vector2.ZERO
	await sim(30)

	# 11 — vine grab attaches
	await reset(p, w)
	var vpos: Vector3 = p.global_position + Vector3(0, 0, -6)
	var g := Gen.height(vpos.x, vpos.z)
	var vid: String = w.add_debug_vine(Vector3(vpos.x, g + 16.0, vpos.z), 13.0)
	p.global_position = Vector3(vpos.x, g + 6.0, vpos.z)
	p.velocity = Vector3.ZERO
	p.state = p.S.AIR
	p.ti.grab = true
	await sim(10)
	check("vine grab attaches", p.state == p.S.SWING and p.swing_vine_id == vid, "state=%d id=%s" % [p.state, p.swing_vine_id])

	# 12 — rope constraint stays taut-or-slack, never stretched
	p.velocity = Vector3(8, 0, 0)
	var maxerr := -99.0
	var max_body_tilt := 0.0
	for i in range(90):
		await get_tree().physics_frame
		if p.state != p.S.SWING:
			break
		maxerr = maxf(maxerr, p.hand_pos().distance_to(p.swing_anchor) - p.swing_len)
		max_body_tilt = maxf(max_body_tilt,
			Vector2(p.rig.hips.rotation.x, p.rig.hips.rotation.z).length())
	check("rope constraint holds", p.state == p.S.SWING and maxerr < 0.5, "err=%.2f state=%d" % [maxerr, p.state])
	check("swing body tilts with pendulum forces", max_body_tilt > 0.12,
		"max tilt=%.2f" % max_body_tilt)

	# 13 — pumping builds swing speed
	var s0: float = p.velocity.length()
	p.ti.dir = Vector2(0, -1)
	await sim(160)
	var s1: float = p.velocity.length()
	check("pumping builds speed", p.state == p.S.SWING and s1 > maxf(s0 + 3.0, 9.0), "s0=%.1f s1=%.1f" % [s0, s1])

	# 14 — release keeps momentum (plus fling boost)
	var pre_s: float = p.velocity.length()
	p.ti.dir = Vector2.ZERO
	p.ti.grab = false
	await sim(2)
	check("release keeps momentum", p.state != p.S.SWING and p.velocity.length() >= pre_s * 0.85,
		"pre=%.1f post=%.1f" % [pre_s, p.velocity.length()])
	var released_started: bool = Gen.vines.has(vid) and bool(Gen.vines[vid].get("simulated", false))
	var released_tip0 := Vector3.ZERO
	if released_started:
		var release_points: PackedVector3Array = Gen.vines[vid].points
		released_tip0 = release_points[release_points.size() - 1]
	await sim(20)
	var released_moved := false
	if Gen.vines.has(vid) and bool(Gen.vines[vid].get("simulated", false)):
		var moved_points: PackedVector3Array = Gen.vines[vid].points
		released_moved = moved_points[moved_points.size() - 1].distance_to(released_tip0) > 0.15
	check("released vine keeps a live physics chain", released_started)
	check("released vine preserves swing momentum", released_moved)

	# 15 — reeling in shortens the rope
	# Reset this fixture: the released vine is deliberately no longer at its
	# original hanging position, while this test is only about reeling.
	Gen.stop_vine_simulation(vid)
	w.claim_vine(vid)
	await sim(30)
	p.global_position = Vector3(vpos.x, g + 6.0, vpos.z)
	p.velocity = Vector3.ZERO
	p.state = p.S.AIR
	p.ti.grab = true
	await sim(15)
	var l0: float = p.swing_len
	p.ti.reel = -1.0
	await sim(60)
	var l1: float = p.swing_len
	p.ti.reel = 0.0
	check("reel-in shortens rope", p.state == p.S.SWING and (l0 - l1) > 3.0, "l0=%.1f l1=%.1f state=%d" % [l0, l1, p.state])
	p.ti.grab = false
	await sim(5)

	# 16 — wall jump kicks away from a trunk-like wall
	await reset(p, w)
	var wp: Vector3 = p.global_position + Vector3(3.0, 0, 0)
	var wg := Gen.height(wp.x, wp.z)
	w.add_debug_wall(Vector3(wp.x + 1.0, wg + 3.0, wp.z), Vector3(1.0, 6.0, 6.0))
	p.global_position = Vector3(wp.x, wg + 2.5, wp.z)
	p.velocity = Vector3.ZERO
	p.state = p.S.AIR
	p.ti.dir = Vector2(1, 0)
	p.ti.jump_held = true
	await sim(14)
	p.ti.jump_just = true
	await sim(3)
	p.ti.jump_held = false
	check("wall jump kicks away", p.velocity.x < -2.0 and p.velocity.y > 3.0, "v=%s" % str(p.velocity))
	p.ti.dir = Vector2.ZERO
	await sim(60)

	# 17 — infinite streaming: far chunks appear, old ones free, ground is real
	p.global_position = Vector3(400.0, Gen.height(400, 400) + 5.0, 400.0)
	p.velocity = Vector3.ZERO
	p.state = p.S.AIR
	await sim(150)
	check("far chunks stream in", w.chunks.has(Vector2i(8, 8)) and p.is_on_floor(),
		"chunks=%d floor=%s" % [w.chunks.size(), str(p.is_on_floor())])
	check("old chunks freed", not w.chunks.has(Vector2i.ZERO), "n=%d" % w.chunks.size())
	var horizon_center: Vector2i = w.center_horizon_sector()
	var horizon_ready: bool = w.horizon_chunks.has(horizon_center) \
		and w._horizon_queue.is_empty() \
		and w.horizon_chunks.size() <= int(pow(Gen.HORIZON_DROP_R * 2 + 1, 2))
	check("coarse horizon streams independently and drains its bounded queue",
		horizon_ready, "sectors=%d queue=%d center=%s" % [
			w.horizon_chunks.size(), w._horizon_queue.size(), horizon_center])
	var registries_clean := true
	for banana_id in w._banana_nodes:
		if not is_instance_valid(w._banana_nodes[banana_id]):
			registries_clean = false
			break
	check("unloaded chunks leave no stale banana registry entries",
		registries_clean, "registry=%d" % w._banana_nodes.size())

	# 18 — banana pickup scores
	var bpos: Vector3 = p.global_position + Vector3(2.0, 1.0, 0)
	w.add_debug_banana(bpos, "b:test#1")
	var score0 := int(Net.scores.get(1, 0))
	p.global_position = bpos
	p.velocity = Vector3.ZERO
	await sim(10)
	check("banana pickup scores", int(Net.scores.get(1, 0)) == score0 + 1, "score=%d" % int(Net.scores.get(1, 0)))

	# 19 — void safety respawn
	p.global_position.y = -40.0
	await sim(5)
	check("void respawn", p.global_position.y > -10.0, "y=%.1f" % p.global_position.y)

	# 20 — absolute speed cap
	p.state = p.S.AIR
	p.velocity = Vector3(200, 40, 0)
	await sim(2)
	check("absolute speed cap", p.velocity.length() <= p.ABS_MAX + 1.0, "%.1f" % p.velocity.length())

	# 21 — grab range is realistic: nothing targeted from afar, near vine acquired
	await reset(p, w)
	var apos: Vector3 = p.global_position
	check("nothing targeted beyond reach", p.last_target.is_empty(), "target=%s" % str(p.last_target))
	var ag := Gen.height(apos.x, apos.z - 2.4)
	w.add_debug_vine(Vector3(apos.x, ag + 13.0, apos.z - 2.4), 11.0)
	await sim(3)
	check("near vine targeted (1-3m reach)", not p.last_target.is_empty(), "target=%s" % str(p.last_target))

	# 22 — flying grab: attaches only when in reach, redirects momentum, keeps
	# the full vine (tail trails below the grip)
	var gg := Gen.height(apos.x, apos.z)
	w.add_debug_vine(Vector3(apos.x, gg + 16.0, apos.z), 10.0)
	p.global_position = Vector3(apos.x, gg + 8.0, apos.z + 6.0)
	p.velocity = Vector3(0, 0, -15.0)
	p.state = p.S.AIR
	p.ti.grab = true
	await sim(30)
	var sp_after: float = p.velocity.length()
	check("chained grab keeps momentum", p.state == p.S.SWING and sp_after >= 12.0,
		"v=%.1f state=%d" % [sp_after, p.state])
	check("vine keeps full length (tail below grip)",
		p.state == p.S.SWING and p.swing_vine_len - p.swing_len > 0.5 and p.rope_tail() > 0.5,
		"vine=%.1f rope=%.1f" % [p.swing_vine_len, p.swing_len])

	# 23 — IK: the left support paw sits on the rope while the right keeps the
	# equipped weapon raised.
	await sim(20)
	var grip: Vector3 = p.hand_pos() + (
		p.swing_anchor - p.hand_pos()).normalized() * 0.12
	var paw: Vector3 = p.rig.el_l.to_global(Vector3(0, -p.rig.ARM_B, 0))
	check("swing support hand touches rope",
		p.state == p.S.SWING and paw.distance_to(grip) < 0.15,
		"off=%.3f" % paw.distance_to(grip))
	p.ti.grab = false
	await sim(5)

	# 24 — hot landing from a vine → quadruped gallop, faster than sprint
	# (runs -Z through the hero-grove gap, same lane as the sprint test)
	await reset(p, w)
	p.global_position += Vector3(0, 1.0, 0)
	p.velocity = Vector3(0, -1.0, -12.5)
	p.state = p.S.AIR
	p.ti.dir = Vector2(0, -1)
	await sim(30)
	check("fast landing enters gallop", p.galloping and p.is_on_floor(), "gallop=%s floor=%s" % [str(p.galloping), str(p.is_on_floor())])
	check("gallop stows weapon on back",
		p.active_weapon.get_parent() == p.rig.weapon_back_mount,
		"parent=%s" % p.active_weapon.get_parent().name)
	await sim(90)
	check("gallop faster than sprint", p.galloping and hspeed(p) >= 11.8, "%.1f" % hspeed(p))
	p.ti.dir = Vector2.ZERO
	await sim(60)
	check("gallop decays to bipedal", not p.galloping, "%.1f" % hspeed(p))
	check("ending gallop returns weapon to hand",
		p.active_weapon.get_parent() == p.rig.el_r,
		"parent=%s" % p.active_weapon.get_parent().name)

	# 25 — hitbox flush: standing monkey's feet are on the terrain surface
	await reset(p, w)
	var gap: float = p.global_position.y - Gen.height(p.global_position.x, p.global_position.z)
	check("hitbox flush with ground", p.is_on_floor() and absf(gap) < 0.2, "gap=%.2f" % gap)

	# 26 — denser jungle: ~11+/chunk averaged over mixed regions (lakes included)
	var tree_total := 0
	for region in [[3, 9], [10, -5], [-8, 4], [20, 20], [5, 8]]:
		for dx in range(4):
			tree_total += Gen.chunk_layout(region[0] + dx, region[1]).trees.size()
	check("jungle density increased", tree_total >= 170, "trees in 20 chunks=%d" % tree_total)

	# 27 — grabbing from the ground reels in smoothly: no snap-fling
	await reset(p, w)
	var s27: Vector3 = p.global_position + Vector3(8, 0, 0)
	var g27 := Gen.height(s27.x, s27.z)
	w.add_debug_vine(Vector3(s27.x, g27 + 14.0, s27.z), 11.5)
	p.global_position = Vector3(s27.x, g27 + 0.3, s27.z)
	p.velocity = Vector3.ZERO
	p.state = p.S.AIR
	await sim(20)
	p.ti.grab = true
	await sim(4)
	var grabbed: bool = p.state == p.S.SWING
	var max_sp := 0.0
	for i in range(60):
		await get_tree().physics_frame
		max_sp = maxf(max_sp, p.velocity.length())
	check("ground grab is smooth (no fling)", grabbed and max_sp < 11.0,
		"max=%.1f grabbed=%s" % [max_sp, str(grabbed)])
	p.ti.grab = false
	await sim(10)

	# 28 — the rope wraps around geometry instead of phasing through, and
	# unwinds when the swing comes back
	var s28: Vector3 = p.global_position + Vector3(-16, 0, 0)
	var g28 := Gen.height(s28.x, s28.z)
	w.add_debug_vine(Vector3(s28.x, g28 + 14.0, s28.z), 11.0)
	w.add_debug_wall(Vector3(s28.x + 1.6, g28 + 9.0, s28.z), Vector3(0.6, 8.0, 8.0))
	p.global_position = Vector3(s28.x, g28 + 0.3, s28.z)
	p.velocity = Vector3.ZERO
	p.state = p.S.AIR
	await sim(20)
	p.ti.grab = true
	await sim(40)
	p.velocity = Vector3(10, 0, 0)
	var wrapped := false
	var max_sp2 := 0.0
	for i in range(240):
		await get_tree().physics_frame
		max_sp2 = maxf(max_sp2, p.velocity.length())
		if p.wraps.size() > 0:
			wrapped = true
			break
	check("rope wraps around obstacle", wrapped and p.state == p.S.SWING,
		"wraps=%d state=%d" % [p.wraps.size(), p.state])
	p.velocity = Vector3(-9, 0, 0)
	var unwrapped := false
	for i in range(240):
		await get_tree().physics_frame
		max_sp2 = maxf(max_sp2, p.velocity.length())
		if p.wraps.size() == 0:
			unwrapped = true
			break
	check("rope unwinds when swing returns", unwrapped, "wraps=%d" % p.wraps.size())
	check("no fling during wrap", max_sp2 < p.SWING_MAX + 1.0, "max=%.1f" % max_sp2)
	p.ti.grab = false

	# 29 — a fast vine release starts a frontflip, which ends on landing
	await reset(p, w)
	var f29: Vector3 = p.global_position
	var fg := Gen.height(f29.x, f29.z)
	w.add_debug_vine(Vector3(f29.x, fg + 16.0, f29.z), 10.0)
	p.global_position = Vector3(f29.x, fg + 8.0, f29.z + 6.0)
	p.velocity = Vector3(0, 0, -17.0)
	p.state = p.S.AIR
	p.ti.grab = true
	await sim(30)
	var flip_speed: float = p.velocity.length()
	p.ti.grab = false
	await sim(3)
	check("fast release starts a frontflip", p.flipping and p.flip_dir == 1
		and p._anim() == MonkeyRig.Anim.FLIP_F,
		"v=%.1f flip=%s dir=%d" % [flip_speed, str(p.flipping), p.flip_dir])
	await sim(150)
	check("flip ends on landing", not p.flipping, "state=%d" % p.state)

	# 30 — flying backward relative to facing flips the other way
	# (fresh vine: the one from test 29 is still a live physics sim mid-whip)
	await sim(50)
	var f30x := f29.x + 10.0
	var fg30 := Gen.height(f30x, f29.z)
	w.add_debug_vine(Vector3(f30x, fg30 + 16.0, f29.z), 10.0)
	p.global_position = Vector3(f30x, fg30 + 8.0, f29.z - 6.0)
	p.velocity = Vector3(0, 0, 17.0)
	p.state = p.S.AIR
	p.ti.grab = true
	var attached30 := false
	for i in range(30):
		await get_tree().physics_frame
		attached30 = attached30 or p.state == p.S.SWING
	p.ti.grab = false
	await sim(3)
	check("backward release backflips", p.flipping and p.flip_dir == -1,
		"dir=%d flip=%s attached=%s" % [p.flip_dir, str(p.flipping), str(attached30)])
	await sim(150)

	# 31/32 — deep lakes float the monkey: swim, then hop out
	var lake := Vector3.ZERO
	var lake_ok := false
	for r in range(16, 150, 6):
		if lake_ok:
			break
		for ang in range(0, 360, 15):
			var wx := f29.x + cos(deg_to_rad(ang)) * r
			var wz := f29.z + sin(deg_to_rad(ang)) * r
			if Gen.WATER_Y - Gen.height(wx, wz) > 1.4:
				lake = Vector3(wx, 0, wz)
				lake_ok = true
				break
	p.global_position = Vector3(lake.x, Gen.WATER_Y + 2.5, lake.z)
	p.velocity = Vector3.ZERO
	p.state = p.S.AIR
	p.ti.dir = Vector2.ZERO
	await sim(80)
	check("deep water floats the monkey (swim)", lake_ok and p.state == p.S.SWIM
		and absf(p.global_position.y - (Gen.WATER_Y - 0.16)) < 0.5,
		"found=%s y=%.2f state=%d" % [str(lake_ok), p.global_position.y, p.state])
	p.ti.jump_just = true
	await sim(4)
	check("SPACE hops out of the water", p.state == p.S.AIR and p.velocity.y > 4.0,
		"vy=%.1f state=%d" % [p.velocity.y, p.state])

	# 33/34 — reversing direction at speed plants a skid that sheds speed
	await reset(p, w)
	p.ti.dir = Vector2(0, -1)
	p.ti.sprint = true
	await sim(80)
	var pre_skid := hspeed(p)
	p.ti.dir = Vector2(0, 1)
	await sim(4)
	check("reversing at speed skids", p.skid_t > 0.0
		and p._anim() == MonkeyRig.Anim.SKID,
		"skid=%.2f pre=%.1f" % [p.skid_t, pre_skid])
	var min_sp := 99.0
	for i in range(30):
		await get_tree().physics_frame
		min_sp = minf(min_sp, hspeed(p))
	check("skid sheds speed before reversing", min_sp < pre_skid * 0.45,
		"%.1f -> min %.1f" % [pre_skid, min_sp])
	p.ti.dir = Vector2.ZERO
	p.ti.sprint = false

	# 35/36 — sprinting drops to all fours, and short hops keep the bound
	# stretched instead of standing the monkey upright mid-air
	await reset(p, w)
	p.ti.dir = Vector2(0, -1)
	p.ti.sprint = true
	await sim(80)
	check("sprint runs on all fours", p._anim() == MonkeyRig.Anim.SPRINT
		and p.is_all_fours(), "anim=%d h=%.1f" % [p._anim(), hspeed(p)])
	p.ti.jump_just = true
	p.ti.jump_held = true
	await sim(10)
	check("gallop bound stays quadruped mid-hop", p.state == p.S.AIR
		and p._anim() == MonkeyRig.Anim.SPRINT,
		"anim=%d state=%d quad=%.2f" % [p._anim(), p.state, p.quad_t])
	p.ti.jump_held = false
	p.ti.sprint = false
	p.ti.dir = Vector2.ZERO

	# 37-43 — render-level locomotion regressions. These drive an isolated rig
	# directly so a correct controller enum cannot hide an animation fallback.
	var motion_rig := MonkeyRig.new()
	motion_rig.setup("MotionTest", false)
	w.add_child(motion_rig)
	motion_rig.global_position = Vector3(0, Gen.height(0, 0), 0)
	motion_rig.set_yaw(0.0)
	motion_rig.set_gun_aim(false, Vector3.FORWARD, 0.0)
	motion_rig.set_melee_pose(false, false, 0.0, 0)
	var frame_dt := 1.0 / 60.0
	var sprint_velocity := Vector3(0, 0, -p.SPRINT_SPEED)

	# Establish the biped reference after its pose blend has settled.
	for i in range(36):
		motion_rig.update_motion(frame_dt, MonkeyRig.Anim.RUN,
			Vector3(0, 0, -p.WALK_SPEED), true, Vector3.ZERO)
	var run_hips_y: float = motion_rig.hips.position.y
	var run_head_height: float = motion_rig.head_p.global_position.y \
		- motion_rig.global_position.y
	var run_spine_forward: float = motion_rig.torso_p.global_transform.basis.y \
		.normalized().dot(sprint_velocity.normalized())

	# SPRINT must advance its own gait clock and settle into a low, forward-spined
	# quadruped instead of silently reusing RUN.
	var sprint_phase_start: float = motion_rig._gait_cycle
	var sprint_phase_motion := 0.0
	for i in range(36):
		motion_rig.update_motion(frame_dt, MonkeyRig.Anim.SPRINT,
			sprint_velocity, true, Vector3.ZERO)
		sprint_phase_motion = maxf(sprint_phase_motion,
			absf(motion_rig._gait_cycle - sprint_phase_start))
	check("rendered sprint gait cycle advances", sprint_phase_motion > 0.01,
		"phase %.3f -> %.3f" % [sprint_phase_start, motion_rig._gait_cycle])
	var sprint_head_height: float = motion_rig.head_p.global_position.y \
		- motion_rig.global_position.y
	var sprint_spine_forward: float = motion_rig.torso_p.global_transform.basis.y \
		.normalized().dot(sprint_velocity.normalized())
	var sprint_is_low := motion_rig.hips.position.y < run_hips_y - 0.06 \
		and sprint_head_height < run_head_height - 0.10
	var sprint_is_pronograde := sprint_spine_forward > 0.35 \
		and sprint_spine_forward > run_spine_forward + 0.25
	check("rendered sprint is a lowered pronograde quadruped",
		sprint_is_low and sprint_is_pronograde,
		"hips %.2f->%.2f head %.2f->%.2f spine %.2f->%.2f" % [
			run_hips_y, motion_rig.hips.position.y, run_head_height,
			sprint_head_height, run_spine_forward, sprint_spine_forward])

	# Sample more than a complete stride and require phase-driven motion from the
	# axial body, tail, and every limb. Endpoint tests remain valid whether a limb
	# is FK-driven or world-planted by IK.
	var sprint_torso_start := motion_rig.torso_p.global_transform
	var sprint_head_start := motion_rig.head_p.global_transform
	var sprint_tail: Node3D = motion_rig.tail_segs[motion_rig.tail_segs.size() - 1]
	var sprint_tail_start := sprint_tail.global_transform
	var sprint_limb_start := rig_limb_endpoints(motion_rig)
	var sprint_torso_motion := 0.0
	var sprint_head_motion := 0.0
	var sprint_tail_motion := 0.0
	var sprint_limb_motion := [0.0, 0.0, 0.0, 0.0]
	for i in range(90):
		motion_rig.update_motion(frame_dt, MonkeyRig.Anim.SPRINT,
			sprint_velocity, true, Vector3.ZERO)
		sprint_torso_motion = maxf(sprint_torso_motion,
			transform_motion(motion_rig.torso_p, sprint_torso_start))
		sprint_head_motion = maxf(sprint_head_motion,
			transform_motion(motion_rig.head_p, sprint_head_start))
		sprint_tail_motion = maxf(sprint_tail_motion,
			transform_motion(sprint_tail, sprint_tail_start))
		var limb_points := rig_limb_endpoints(motion_rig)
		for limb_i in range(4):
			sprint_limb_motion[limb_i] = maxf(sprint_limb_motion[limb_i],
				limb_points[limb_i].distance_to(sprint_limb_start[limb_i]))
	check("quadruped stride animates torso, head, and tail",
		sprint_torso_motion > 0.006 and sprint_head_motion > 0.006 \
			and sprint_tail_motion > 0.012,
		"torso=%.3f head=%.3f tail=%.3f" % [sprint_torso_motion,
			sprint_head_motion, sprint_tail_motion])
	check("quadruped stride animates all four limbs",
		sprint_limb_motion[0] > 0.025 and sprint_limb_motion[1] > 0.025 \
			and sprint_limb_motion[2] > 0.025 and sprint_limb_motion[3] > 0.025,
		"FL=%.3f FR=%.3f HL=%.3f HR=%.3f" % sprint_limb_motion)

	# The visible tail must overlap continuously from the pelvis socket into the
	# first articulated capsule, even when its root is counter-rotated.
	var tail_root: Node3D = motion_rig.tail_segs[0]
	var tail_socket := tail_root.get_node_or_null("TailSocket") as MeshInstance3D
	var tail_bridge := tail_root.get_node_or_null("TailRootBridge") as MeshInstance3D
	var first_tail_joint: Node3D = motion_rig.tail_segs[1]
	var first_tail_mesh := first_tail_joint.get_child(0) as MeshInstance3D
	var tail_overlap := -INF
	if tail_socket and tail_bridge and first_tail_mesh \
			and tail_bridge.mesh is CapsuleMesh \
			and first_tail_mesh.mesh is CapsuleMesh:
		var bridge_end: float = tail_bridge.position.z \
			+ (tail_bridge.mesh as CapsuleMesh).height * 0.5
		var first_start: float = first_tail_joint.position.z \
			+ first_tail_mesh.position.z \
			- (first_tail_mesh.mesh as CapsuleMesh).height * 0.5
		tail_overlap = bridge_end - first_start
	check("tail root stays visibly connected to the body",
		tail_socket != null and tail_bridge != null and tail_overlap > 0.015,
		"socket=%s bridge=%s overlap=%.3f" % [str(tail_socket != null),
			str(tail_bridge != null), tail_overlap])
	var tail_core_radii: Array[float] = []
	var tail_fur_count := 0
	for joint_index in range(1, motion_rig.tail_segs.size()):
		var tail_joint: Node3D = motion_rig.tail_segs[joint_index]
		var tail_core := tail_joint.get_node_or_null("TailCore") as MeshInstance3D
		if tail_core and tail_core.mesh is CapsuleMesh:
			tail_core_radii.append((tail_core.mesh as CapsuleMesh).radius)
		if tail_joint.get_node_or_null("TailFur") is MeshInstance3D:
			tail_fur_count += 1
	var tail_width_spread := INF
	var tail_min_radius := 0.0
	if not tail_core_radii.is_empty():
		tail_min_radius = tail_core_radii.min()
		tail_width_spread = tail_core_radii.max() - tail_min_radius
	var final_tail_joint: Node3D = motion_rig.tail_segs[
		motion_rig.tail_segs.size() - 1]
	var tail_tip := final_tail_joint.get_node_or_null("TailTipTuft")
	check("tail keeps a full uniform furry silhouette",
		tail_core_radii.size() == MonkeyRig.TAIL_SEGMENTS \
			and tail_width_spread < 0.001 and tail_min_radius >= 0.05 \
			and tail_fur_count == MonkeyRig.TAIL_SEGMENTS \
			and tail_tip is MeshInstance3D,
		"cores=%d radius=%.3f spread=%.4f fur=%d tip=%s" % [
			tail_core_radii.size(), tail_min_radius, tail_width_spread,
			tail_fur_count, str(tail_tip is MeshInstance3D)])

	# IK supplies full 3D bases during the quadruped gait. On exit, hips, knees,
	# and feet must shed the lateral/twist components and become hinge joints
	# again instead of carrying the last all-fours terrain pose into RUN/IDLE.
	for i in range(24):
		motion_rig.update_motion(frame_dt, MonkeyRig.Anim.SPRINT,
			sprint_velocity, true, Vector3.ZERO)
	var leg_joints: Array[Node3D] = [motion_rig.hip_l, motion_rig.kn_l,
		motion_rig.hip_r, motion_rig.kn_r, motion_rig.foot_l, motion_rig.foot_r]
	var sprint_leg_twist := 0.0
	for joint in leg_joints:
		sprint_leg_twist += absf(joint.rotation.y) + absf(joint.rotation.z)
	var sprint_elbow_twist: float = absf(motion_rig.el_l.rotation.y) \
		+ absf(motion_rig.el_l.rotation.z) + absf(motion_rig.el_r.rotation.y) \
		+ absf(motion_rig.el_r.rotation.z)
	for i in range(72):
		motion_rig.update_motion(frame_dt, MonkeyRig.Anim.RUN,
			Vector3(0, 0, -p.WALK_SPEED), true, Vector3.ZERO)
	var restored_leg_twist := 0.0
	for joint in leg_joints:
		restored_leg_twist += absf(joint.rotation.y) + absf(joint.rotation.z)
	var restored_elbow_twist: float = absf(motion_rig.el_l.rotation.y) \
		+ absf(motion_rig.el_l.rotation.z) + absf(motion_rig.el_r.rotation.y) \
		+ absf(motion_rig.el_r.rotation.z)
	check("legs restore their normal axes after quadruped sprint",
		sprint_leg_twist > 0.05 and restored_leg_twist < 0.025,
		"twist %.3f -> %.3f" % [sprint_leg_twist, restored_leg_twist])
	check("elbows restore their normal axes after quadruped sprint",
		sprint_elbow_twist > 0.03 and restored_elbow_twist < 0.015,
		"twist %.3f -> %.3f" % [sprint_elbow_twist, restored_elbow_twist])

	# Swimming uses a separate cadence but must likewise advance and alternate
	# both the crawl arms and flutter-kicking legs while the body rolls and the
	# head/tail counterbalance.
	var swim_velocity := Vector3(0, 0, -p.SWIM_SPEED)
	var swim_phase_start: float = motion_rig._gait_cycle
	var swim_phase_motion := 0.0
	for i in range(30):
		motion_rig.update_motion(frame_dt, MonkeyRig.Anim.SWIM,
			swim_velocity, false, Vector3.ZERO)
		swim_phase_motion = maxf(swim_phase_motion,
			absf(motion_rig._gait_cycle - swim_phase_start))
	check("swim stroke cycle advances", swim_phase_motion > 0.01,
		"phase %.3f -> %.3f" % [swim_phase_start, motion_rig._gait_cycle])
	var swim_torso_start := motion_rig.torso_p.global_transform
	var swim_head_start := motion_rig.head_p.global_transform
	var swim_tail: Node3D = motion_rig.tail_segs[motion_rig.tail_segs.size() - 1]
	var swim_tail_start := swim_tail.global_transform
	var swim_limb_start := rig_limb_endpoints(motion_rig)
	var swim_torso_motion := 0.0
	var swim_head_motion := 0.0
	var swim_tail_motion := 0.0
	var swim_limb_motion := [0.0, 0.0, 0.0, 0.0]
	var arm_difference_min := INF
	var arm_difference_max := -INF
	var leg_difference_min := INF
	var leg_difference_max := -INF
	for i in range(120):
		motion_rig.update_motion(frame_dt, MonkeyRig.Anim.SWIM,
			swim_velocity, false, Vector3.ZERO)
		swim_torso_motion = maxf(swim_torso_motion,
			transform_motion(motion_rig.torso_p, swim_torso_start))
		swim_head_motion = maxf(swim_head_motion,
			transform_motion(motion_rig.head_p, swim_head_start))
		swim_tail_motion = maxf(swim_tail_motion,
			transform_motion(swim_tail, swim_tail_start))
		var swim_limb_points := rig_limb_endpoints(motion_rig)
		for limb_i in range(4):
			swim_limb_motion[limb_i] = maxf(swim_limb_motion[limb_i],
				swim_limb_points[limb_i].distance_to(swim_limb_start[limb_i]))
		var arm_difference: float = motion_rig.sh_l.rotation.x \
			- motion_rig.sh_r.rotation.x
		var leg_difference: float = motion_rig.hip_l.rotation.x \
			- motion_rig.hip_r.rotation.x
		arm_difference_min = minf(arm_difference_min, arm_difference)
		arm_difference_max = maxf(arm_difference_max, arm_difference)
		leg_difference_min = minf(leg_difference_min, leg_difference)
		leg_difference_max = maxf(leg_difference_max, leg_difference)
	check("swim alternates crawl arms and flutter-kicking legs",
		arm_difference_min < -0.15 and arm_difference_max > 0.15 \
			and leg_difference_min < -0.08 and leg_difference_max > 0.08,
		"arms=[%.2f,%.2f] legs=[%.2f,%.2f]" % [arm_difference_min,
			arm_difference_max, leg_difference_min, leg_difference_max])
	check("swim stroke animates full body, tail, and all limbs",
		swim_torso_motion > 0.006 and swim_head_motion > 0.006 \
			and swim_tail_motion > 0.012 and swim_limb_motion[0] > 0.025 \
			and swim_limb_motion[1] > 0.025 and swim_limb_motion[2] > 0.025 \
			and swim_limb_motion[3] > 0.025,
		"body=%.3f head=%.3f tail=%.3f limbs=%s" % [swim_torso_motion,
			swim_head_motion, swim_tail_motion, str(swim_limb_motion)])
	motion_rig.free()

	# 44/45 — procedural water follows the same macro waves as buoyancy and its
	# runtime contacts reuse bounded pools instead of allocating every stroke.
	var water_y0 := Visuals.water_surface_y(11.0, -7.0, 0.0)
	var water_y1 := Visuals.water_surface_y(11.0, -7.0, 0.85)
	check("water surface waves are animated and physically bounded",
		absf(water_y1 - water_y0) > 0.001 \
			and absf(water_y0 - Gen.WATER_Y) < 0.11 \
			and absf(water_y1 - Gen.WATER_Y) < 0.11,
		"y0=%.3f y1=%.3f" % [water_y0, water_y1])
	var water_fx: WaterFX = w.water_fx
	var ring_pool_size: int = water_fx._rings.size()
	var foam_pool_size: int = water_fx._foams.size()
	var spray_pool_size: int = water_fx._sprays.size()
	var fx_point := Vector3(lake.x, Gen.WATER_Y, lake.z)
	water_fx.entry_splash(fx_point, Vector3(1.0, -8.0, -2.0), 1.0)
	water_fx.stroke(fx_point + Vector3(0.3, 0, 0), Vector3(0, 0, -4.8), -1, 0.8)
	water_fx.kick(fx_point - Vector3(0.3, 0, 0), Vector3(0, 0, -4.8), 0.4)
	for i in range(ring_pool_size + 5):
		water_fx.emit_ripple(fx_point + Vector3(i * 0.03, 0, 0), 0.3, 0.8, 0.6)
	await sim(2)
	var active_rings := 0
	for ring in water_fx._rings:
		active_rings += 1 if bool(ring.active) else 0
	check("water contacts reuse bounded ripple, foam, and spray pools",
		water_fx._rings.size() == ring_pool_size \
			and water_fx._foams.size() == foam_pool_size \
			and water_fx._sprays.size() == spray_pool_size \
			and active_rings <= ring_pool_size \
			and int(water_fx._water_material.get_shader_parameter("ripple_count")) \
				<= water_fx.MAX_SHADER_RIPPLES,
		"rings=%d/%d foam=%d spray=%d shader=%d" % [active_rings,
			ring_pool_size, foam_pool_size, spray_pool_size,
			int(water_fx._water_material.get_shader_parameter("ripple_count"))])

	print("MOVETEST %d/%d %s" % [total - fails, total, "PASS" if fails == 0 else "FAIL"])
	get_tree().quit(1 if fails > 0 else 0)
