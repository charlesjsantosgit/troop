extends Node
## Headless regression checks for smooth online entry and PTT input cooldown:
##   godot --headless --path . -- onlineperformancetest

var passed := 0
var total := 0


func run() -> void:
	Gen.setup(20260805)
	var world := World.new()
	world.process_mode = Node.PROCESS_MODE_DISABLED
	add_child(world)
	world.warm_online_entry()
	_check(world.chunks.size() == 1,
		"online entry builds only the playable center chunk")
	var spawn_pos := world.spawn_position(1)
	var spawn_chunk := Vector2i(floori(spawn_pos.x / Gen.CHUNK),
		floori(spawn_pos.z / Gen.CHUNK))
	var center_chunk = world.chunks.get(spawn_chunk)
	_check(center_chunk != null and center_chunk.has_collisions(),
		"online center chunk is collision-ready before spawning")
	_check(world.horizon_chunks.is_empty(),
		"online entry leaves horizon generation to the frame budget")
	var collider: ConcavePolygonShape3D = center_chunk._collision_bodies[0].get_child(0).shape
	var expected: ConcavePolygonShape3D = center_chunk._terrain_mesh.create_trimesh_shape()
	_check(collider.get_faces() == expected.get_faces() and collider.backface_collision,
		"CPU terrain collision exactly preserves legacy faces, winding and snapping")
	_check(center_chunk._terrain_collision_vertices.is_empty(),
		"the spawn lattice is released after its collider is published")
	var prefetched := Chunk.new()
	prefetched.process_mode = Node.PROCESS_MODE_DISABLED
	add_child(prefetched)
	prefetched.setup(Vector2i(2, -3), {}, false, true, true)
	_check(prefetched._terrain_collision_vertices.size() == 4 and not prefetched.has_collisions(),
		"coarse flight shells retain only four CPU vertices and no collider")
	prefetched.finish_deferred_build()
	_check(prefetched._terrain_collision_vertices.size() == (Gen.CELLS + 1) * (Gen.CELLS + 1),
		"detail promotion replaces the coarse lattice with the exact fine lattice")
	prefetched.set_collision_active(true)
	var promoted: ConcavePolygonShape3D = prefetched._collision_bodies[0].get_child(0).shape
	var promoted_expected: ConcavePolygonShape3D = prefetched._terrain_mesh.create_trimesh_shape()
	_check(promoted.get_faces() == promoted_expected.get_faces() \
		and promoted.backface_collision and prefetched._terrain_collision_vertices.is_empty(),
		"late collision uses fine terrain and releases the CPU lattice without a GPU readback")
	prefetched.free()

	var deadline := 10_000 + VoiceChat.INPUT_IDLE_RELEASE_MSEC
	_check(not VoiceChat.input_release_due(deadline - 1, deadline),
		"PTT input device remains warm during the toggle window")
	_check(VoiceChat.input_release_due(deadline, deadline),
		"PTT input device releases after the warm window")
	_check(not VoiceChat.input_release_due(deadline + 1, 0),
		"PTT input device has no accidental zero-deadline release")

	world.free()
	print("ONLINEPERFORMANCETEST %d/%d %s" % [
		passed, total, "PASS" if passed == total else "FAIL"])
	get_tree().quit(0 if passed == total else 1)


func _check(condition: bool, label: String) -> void:
	total += 1
	if condition:
		passed += 1
		print("  [ok] " + label)
	else:
		print("  [FAIL] " + label)
