extends Node
## Guards online-entry ground safety. The peer-ID spawn jitter can place a
## joining player outside the origin chunk, so warm_online_entry() must prewarm
## the chunk the peer actually spawns in, and — even if a player ever starts
## over completely unstreamed terrain — the streaming loop must deliver
## collision long before gravity can carry them through the terrain shell.

const PROBE_PEER_ID := 25  # % 5 == 0 and / 5 % 5 == 0 -> jitter (-2, 0, -2)
const SETTLE_FRAMES := 300
const COLLISION_FRAME_BUDGET := 20  # 1/3 s of 60 Hz physics; spawn is 2.5 m up

var total := 0
var passed := 0


func run(main) -> void:
	# Phase 1: the real join path. The prewarmed chunk must be the one under
	# the jittered spawn, solid before the first physics frame.
	Gen.setup(4242)
	var world: World = load("res://scripts/world.gd").new()
	main.add_child(world)
	world.build()
	world.warm_online_entry(PROBE_PEER_ID)
	var player := world.spawn_local(PROBE_PEER_ID, "EntryProbe")
	player.test_mode = true
	var spawn_chunk := _chunk_under(player.global_position)
	_check(spawn_chunk != Vector2i.ZERO,
		"the probe peer's jitter spawns outside the origin chunk")
	var warm_chunk = world.chunks.get(spawn_chunk)
	_check(warm_chunk != null and warm_chunk.has_collisions(),
		"online entry prewarms the jittered spawn chunk with collision")
	world.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame

	# Phase 2: harsher than any real entry — no prewarm at all. Streaming alone
	# must still make the spawn chunk solid within a fraction of the fall time.
	Gen.setup(4242)
	world = load("res://scripts/world.gd").new()
	main.add_child(world)
	world.build()
	player = world.spawn_local(PROBE_PEER_ID, "StreamProbe")
	player.test_mode = true
	spawn_chunk = _chunk_under(player.global_position)

	var fell_through := false
	var landed := false
	var collision_frame := -1
	for i in range(SETTLE_FRAMES):
		await get_tree().physics_frame
		var chunk = world.chunks.get(spawn_chunk)
		if collision_frame < 0 and chunk != null and chunk.has_collisions():
			collision_frame = i
		var pos := player.global_position
		if pos.y < Gen.height(pos.x, pos.z) - 1.0:
			fell_through = true
		if player.is_on_floor():
			landed = true

	_check(collision_frame >= 0
			and collision_frame <= COLLISION_FRAME_BUDGET,
		"an unwarmed spawn chunk gains collision within %d physics frames (got %d)"
			% [COLLISION_FRAME_BUDGET, collision_frame])
	_check(not fell_through,
		"the player never sinks below the terrain surface while streaming")
	_check(landed,
		"the player lands on solid ground near the jittered spawn")

	print("ENTRYTEST %d/%d %s" % [passed, total,
		"PASS" if passed == total else "FAIL"])
	await get_tree().process_frame
	get_tree().quit(0 if passed == total else 1)


func _chunk_under(pos: Vector3) -> Vector2i:
	return Vector2i(floori(pos.x / Gen.CHUNK), floori(pos.z / Gen.CHUNK))


func _check(condition: bool, label: String) -> void:
	total += 1
	if condition:
		passed += 1
		print("  [ok] " + label)
	else:
		print("  [FAIL] " + label)
