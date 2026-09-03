extends SceneTree
## Real World construction parity plus in-flight authoritative registrations.
##   godot --headless --path . --script res://tests/worldstagedbuildtest.gd
## Run without --headless, alone, to report cold renderer-stage timings too.

var passed := 0
var total := 0
var stage_timings: Array[Dictionary] = []


class EntryPeerSpy extends Node3D:
	var shots := 0
	var melees := 0
	var defeats := 0

	func on_shot(_direction: Vector3, _weapon_kind: int) -> void:
		shots += 1

	func on_melee(_direction: Vector3, _combo: int) -> void:
		melees += 1

	func begin_defeat(_pos: Vector3, _yaw: float, _velocity: Vector3,
			_impulse: Vector3, _headshot: bool) -> void:
		defeats += 1


func _initialize() -> void:
	call_deferred("_run")


func _check(ok: bool, label: String) -> void:
	total += 1
	passed += int(ok)
	print("  [%s] %s" % ["ok" if ok else "FAIL", label])


func _node_signature(node: Node, counts: Dictionary) -> void:
	var kind := node.get_class()
	counts[kind] = int(counts.get(kind, 0)) + 1
	for child in node.get_children():
		_node_signature(child, counts)


func _signature(world) -> Dictionary:
	var nodes := {}
	_node_signature(world, nodes)
	return {
		"nodes": nodes,
		"rings": world.water_fx._rings.size(),
		"foams": world.water_fx._foams.size(),
		"sprays": world.water_fx._sprays.size(),
		"stars": world._celestial_sky.star_count(),
		"sun_shadows": world._sun.shadow_enabled,
		"moon_shadows": world._moon.shadow_enabled,
		"particles": world._particles.amount,
		"vehicles": world.vehicles.size(),
	}


func _water_signature(water_fx) -> Dictionary:
	var nodes := {}
	_node_signature(water_fx, nodes)
	var spray_settings := []
	for spray in water_fx._sprays:
		spray_settings.append([spray.amount, spray.lifetime, spray.one_shot,
			spray.explosiveness, spray.randomness, spray.local_coords,
			spray.fixed_fps, spray.visibility_aabb, spray.draw_pass_1.size])
	return {
		"nodes": nodes,
		"rings": water_fx._rings.size(),
		"foams": water_fx._foams.size(),
		"sprays": spray_settings,
		"ring_shader": water_fx._ring_shader.code,
		"foam_shader": water_fx._foam_shader.code,
		"water_level": water_fx.water_level,
		"audio_bus": water_fx._water_loop.bus,
		"audio_stream": water_fx._water_loop.stream,
	}


func _check_water_shader_cache(first_water, second_water, standalone_water) -> void:
	var ring_a: ShaderMaterial = first_water._rings[0].material
	var ring_b: ShaderMaterial = first_water._rings[1].material
	var ring_other_world: ShaderMaterial = second_water._rings[0].material
	var ring_standalone: ShaderMaterial = standalone_water._rings[0].material
	var foam_a: ShaderMaterial = first_water._foams[0].material
	var foam_other_world: ShaderMaterial = second_water._foams[0].material
	var foam_standalone: ShaderMaterial = standalone_water._foams[0].material
	_check(ring_a.shader == ring_b.shader and ring_a.shader == ring_other_world.shader \
		and ring_a.shader == ring_standalone.shader and ring_a.shader.get_rid().is_valid() \
		and ring_a.shader.get_rid() == ring_other_world.shader.get_rid(),
		"staged, synchronous and standalone water share one immutable ring shader")
	_check(foam_a.shader == foam_other_world.shader \
		and foam_a.shader == foam_standalone.shader and foam_a.shader.get_rid().is_valid() \
		and foam_a.shader.get_rid() == foam_other_world.shader.get_rid() \
		and foam_a.shader != ring_a.shader,
		"water instances share one foam shader distinct from the ring shader")
	_check(ring_a != ring_b and ring_a != ring_other_world \
		and ring_a.get_rid() != ring_b.get_rid() \
		and ring_a.get_rid() != ring_other_world.get_rid() \
		and foam_a != foam_other_world and foam_a.get_rid() != foam_other_world.get_rid(),
		"every pool slot retains its own material resource and uniform storage")
	var ring_fade_a: Variant = ring_a.get_shader_parameter("fade")
	var ring_fade_b: Variant = ring_b.get_shader_parameter("fade")
	var ring_seed_a: Variant = ring_a.get_shader_parameter("seed")
	var ring_peer_fade: Variant = ring_other_world.get_shader_parameter("fade")
	var ring_peer_seed: Variant = ring_other_world.get_shader_parameter("seed")
	var foam_fade_a: Variant = foam_a.get_shader_parameter("fade")
	var foam_peer_fade: Variant = foam_other_world.get_shader_parameter("fade")
	ring_a.set_shader_parameter("fade", 0.25)
	ring_b.set_shader_parameter("fade", 0.75)
	ring_a.set_shader_parameter("seed", 91.0)
	foam_a.set_shader_parameter("fade", 0.6)
	_check(is_equal_approx(float(ring_a.get_shader_parameter("fade")), 0.25) \
		and is_equal_approx(float(ring_b.get_shader_parameter("fade")), 0.75) \
		and ring_other_world.get_shader_parameter("fade") == ring_peer_fade \
		and ring_other_world.get_shader_parameter("seed") == ring_peer_seed \
		and foam_other_world.get_shader_parameter("fade") == foam_peer_fade,
		"ring and foam uniform changes stay local to their pool slot and world")
	_check(ring_a.shader.code == first_water.RING_SHADER \
		and foam_a.shader.code == first_water.FOAM_SHADER,
		"per-effect uniform updates leave both cached shader sources unchanged")
	ring_a.set_shader_parameter("fade", ring_fade_a)
	ring_b.set_shader_parameter("fade", ring_fade_b)
	ring_a.set_shader_parameter("seed", ring_seed_a)
	foam_a.set_shader_parameter("fade", foam_fade_a)


func _check_network_transient_gate(world, net, generator) -> void:
	var peer := EntryPeerSpy.new()
	var peer_id := 80777001
	world.add_child(peer)
	world.puppets[peer_id] = peer
	var vine_id := "v:entry-gate-fixture"
	var original_vine: Variant = generator.vines.get(vine_id)
	var anchor := Vector3(10_000, 10_010, 10_000)
	var shape := PackedVector3Array([anchor, anchor + Vector3.DOWN * 5.0])
	generator.vines[vine_id] = {"anchor": anchor, "chunk": Vector2i(208, 208),
		"hidden": false, "simulated": false, "points": PackedVector3Array()}
	var child_count: int = world.get_child_count()
	var scores: Dictionary = net.scores.duplicate(true)
	for event_index in range(3):
		net.bullet_fired.emit(peer_id, anchor, Vector3.RIGHT * 40.0, 34.0,
			true, true, 0)
		net.melee_swung.emit(peer_id, anchor, Vector3.RIGHT, event_index)
		net.peer_defeated.emit(peer_id, anchor, 0.0, Vector3.ZERO,
			Vector3.ZERO, false)
		net.vine_released.emit(vine_id, shape[1], Vector3.RIGHT, 5.0, shape)
	_check(world.get_child_count() == child_count and peer.shots == 0 \
		and peer.melees == 0 and peer.defeats == 0,
		"entry gate discards live shots, muzzle effects, melee and defeat presentation")
	_check(world._vine_sims.is_empty() and not generator.vines[vine_id].simulated,
		"entry gate discards released-vine simulations without mutating their geometry")
	world.set_network_transient_effects_enabled(true)
	await process_frame
	_check(world.get_child_count() == child_count and peer.shots == 0 \
		and peer.melees == 0 and peer.defeats == 0 and world._vine_sims.is_empty(),
		"activating entry never buffers or replays old transient events")
	# World remains PROCESS_MODE_DISABLED: explicit activation, not can_process,
	# controls event dispatch so normal gameplay pause behavior is unchanged.
	net.bullet_fired.emit(peer_id, anchor, Vector3.RIGHT * 40.0, 34.0,
		true, false, 0)
	_check(world.get_child_count() == child_count + 1,
		"fresh network bullets spawn immediately after explicit activation")
	net.melee_swung.emit(peer_id, anchor, Vector3.RIGHT, 1)
	net.peer_defeated.emit(peer_id, anchor, 0.0, Vector3.ZERO,
		Vector3.ZERO, false)
	net.vine_released.emit(vine_id, shape[1], Vector3.RIGHT, 5.0, shape)
	_check(peer.melees == 1 and peer.defeats == 1 \
		and world._vine_sims.has(vine_id) and generator.vines[vine_id].simulated,
		"fresh melee, defeat and vine events resume even in an ordinarily paused world")
	_check(net.scores == scores,
		"transient entry gating leaves authoritative scores untouched")
	world.puppets.erase(peer_id)
	peer.free()
	if original_vine == null:
		generator.vines.erase(vine_id)
	else:
		generator.vines[vine_id] = original_vine


func _run() -> void:
	print("WORLDSTAGEDBUILDTEST begin")
	var generator = root.get_node("Gen")
	var net = root.get_node("Net")
	var original_seed: int = generator.world_seed
	var original_definitions: Dictionary = net.vehicle_spawn_definitions.duplicate(true)
	var original_rests: Dictionary = net.vehicle_rests.duplicate(true)
	var original_vehicle_claims: Dictionary = net.claimed_vehicles.duplicate(true)
	var original_claims: Dictionary = net.claimed_supply_chests.duplicate(true)
	net.vehicle_spawn_definitions = {
		"v:build#snapshot": {"kind": 1, "pos": Vector3(10, 4, 10), "yaw": 0.2},
	}
	net.vehicle_rests = {}
	net.claimed_vehicles = {}
	net.claimed_supply_chests = {"s:build#early": 1}
	generator.setup(4242)
	# Defer production loading until the project autoloads are initialized.
	var world_script: Script = load("res://scripts/world.gd")
	_check(world_script.can_instantiate(), "World compiles after autoload initialization")
	if not world_script.can_instantiate():
		quit(1)
		return
	var staged = world_script.new()
	_check(staged._network_transient_effects_enabled,
		"network transient effects default on for existing synchronous and offline callers")
	staged.set_network_transient_effects_enabled(false)
	staged.process_mode = Node.PROCESS_MODE_DISABLED
	root.add_child(staged)
	staged.begin_build()
	staged.begin_build()
	_check(not staged.is_build_complete() and staged.get_child_count() == 0,
		"begin_build is idempotent and does not create heavy scene resources")
	_check(staged.vehicles.is_empty() and staged._build_vehicle_queue.size() == 1,
		"the initial authoritative vehicle snapshot is queued instead of built eagerly")
	var late_pos := Vector3(22.0, 5.0, 31.0)
	net.vehicle_spawn_definitions["v:build#late"] = {
		"kind": 0, "pos": late_pos, "yaw": 0.4,
	}
	net.vehicle_spawn_registered.emit("v:build#late", 0, late_pos, 0.4)
	net.vehicle_spawn_registered.emit("v:build#late", 0, late_pos, 0.4)
	_check(staged.vehicles.is_empty() and staged._build_vehicle_queue.size() == 2,
		"late and repeated registrations remain queued once while loading")
	var steps := 0
	var bounded := true
	var water_bounded := true
	var partial_effects_inactive := true
	var updated_pending := false
	while not staged.is_build_complete() and steps < 128:
		var label: String = staged.build_stage_name()
		var vehicles_before: int = staged.vehicles.size()
		var rings_before: int = 0 if staged.water_fx == null else staged.water_fx._rings.size()
		var foams_before: int = 0 if staged.water_fx == null else staged.water_fx._foams.size()
		var sprays_before: int = 0 if staged.water_fx == null else staged.water_fx._sprays.size()
		staged.build_step()
		steps += 1
		stage_timings.append({"stage": label,
			"ms": float(staged.build_last_step_usec()) / 1000.0})
		bounded = bounded and staged.vehicles.size() - vehicles_before <= 1
		if staged.water_fx != null:
			var water_fx = staged.water_fx
			water_bounded = water_bounded and water_fx._rings.size() - rings_before <= 4 \
				and water_fx._foams.size() - foams_before <= 4 \
				and water_fx._sprays.size() - sprays_before <= 1
			if not water_fx.is_setup_complete():
				water_fx.entry_splash(Vector3.ZERO)
				water_fx.emit_ripple(Vector3.ZERO)
				water_fx.set_listener_swimming(true, 2.0)
				water_fx._process(0.016)
				partial_effects_inactive = partial_effects_inactive \
					and water_fx._event_serial == 0 and water_fx._clock == 0.0
		if staged.vehicles.has("v:build#snapshot") and not updated_pending:
			updated_pending = true
			var restored = staged.vehicle_by_id("v:build#snapshot")
			net.claimed_vehicles["v:build#snapshot"] = 42
			net.vehicle_claimed.emit("v:build#snapshot", 42)
			_check(restored.remote_controlled and restored.occupied_by_peer == 42,
				"already-restored vehicles receive seat claims while later vehicles are loading")
			net.claimed_vehicles.erase("v:build#snapshot")
			net.vehicle_rests["v:build#snapshot"] = [Vector3(14, 5, 19), 0.6, 0.0, 0.0]
			net.vehicle_released.emit("v:build#snapshot", net.vehicle_rests["v:build#snapshot"])
			_check(not restored.remote_controlled \
				and restored.global_position.is_equal_approx(Vector3(14, 5, 19)),
				"already-restored vehicles receive release/rest state during staged loading")
			late_pos = Vector3(26.0, 5.0, 33.0)
			net.vehicle_spawn_definitions["v:build#late"].pos = late_pos
			net.vehicle_spawn_registered.emit("v:build#late", 0, late_pos, 0.4)
			net.vehicle_rests["v:build#late"] = [Vector3(28, 6, 35), 0.7, 0.0, 0.0]
			net.claimed_supply_chests["s:build#during"] = 2
			# A registration can extend the queue after draining has started, and
			# its newest definition must win before construction reaches that ID.
			net.vehicle_spawn_registered.emit("v:build#newer", 0, Vector3(30, 5, 35), 0.1)
			net.vehicle_spawn_definitions["v:build#newer"] = {
				"kind": 0, "pos": Vector3(32, 5, 38), "yaw": 0.8,
			}
			net.vehicle_spawn_registered.emit("v:build#newer", 0, Vector3(32, 5, 38), 0.8)
		await process_frame
	_check(staged.is_build_complete() and steps == 31 and bounded,
		"all graphics sub-stages plus three one-vehicle steps complete with bounded restoration")
	_check(water_bounded and staged.water_fx.is_setup_complete(),
		"each water setup step creates at most four mesh nodes or one spray emitter")
	_check(partial_effects_inactive,
		"partial water effects do not animate, emit sound, or dereference unfinished audio")
	_check(staged._build_vehicle_queue.is_empty() \
		and staged._build_vehicle_definitions.is_empty() and staged.vehicles.size() == 3,
		"the staged queue drains every snapshot and late registration without duplicates")
	var late = staged.vehicle_by_id("v:build#late")
	_check(late != null and late.global_position.is_equal_approx(Vector3(28, 6, 35)),
		"resting state arriving during construction is applied when its vehicle materializes")
	var newer = staged.vehicle_by_id("v:build#newer")
	# Registration positions are ground-settled by production spawn_vehicle;
	# unlike release/rest snapshots, their supplied height is not authoritative.
	_check(newer != null and Vector2(newer.global_position.x, newer.global_position.z) \
		.is_equal_approx(Vector2(32, 38)) \
		and is_equal_approx(newer.rotation.y, 0.8),
		"registrations arriving after draining starts use their latest queued definition")
	_check(staged.opened_supply_huts.has("s:build#early") \
		and staged.opened_supply_huts.has("s:build#during"),
		"chest claims received during staged construction survive the final snapshot refresh")
	_check(staged.water_fx._rings.size() == 18 and staged.water_fx._foams.size() == 20 \
		and staged.water_fx._sprays.size() == 8 and staged._particles.amount == 120,
		"staging preserves all water pools and ambient particle features")
	var live_pos := Vector3(40, 5, 40)
	net.vehicle_spawn_definitions["v:build#live"] = {"kind": 2, "pos": live_pos, "yaw": 0.0}
	net.vehicle_spawn_registered.emit("v:build#live", 2, live_pos, 0.0)
	var live_instance = staged.vehicle_by_id("v:build#live")
	net.vehicle_spawn_registered.emit("v:build#live", 2, live_pos, 0.0)
	_check(staged.vehicles.size() == 4 and live_instance != null \
		and staged.vehicle_by_id("v:build#live") == live_instance,
		"completed worlds retain immediate live registration and stable-ID deduplication")
	var child_count: int = staged.get_child_count()
	staged.build()
	_check(staged.get_child_count() == child_count and staged.build_step(),
		"repeated synchronous or staged completion does not duplicate scene resources")
	var synchronous = world_script.new()
	synchronous.process_mode = Node.PROCESS_MODE_DISABLED
	root.add_child(synchronous)
	synchronous.build()
	staged.set_time_of_day_override(12.0)
	synchronous.set_time_of_day_override(12.0)
	_check(_signature(staged) == _signature(synchronous),
		"synchronous and staged paths produce identical scene classes, pools, sky and vehicles")
	_check(staged.build_progress() == 1.0 and synchronous.build_progress() == 1.0,
		"both APIs expose complete progress only after all resources are ready")
	var water_script: Script = load("res://scripts/water_fx.gd")
	var standalone_water = water_script.new()
	standalone_water.process_mode = Node.PROCESS_MODE_DISABLED
	standalone_water.setup(generator.WATER_Y)
	root.add_child(standalone_water)
	_check(standalone_water.is_setup_complete() \
		and _water_signature(staged.water_fx) == _water_signature(standalone_water),
		"standalone synchronous WaterFX readiness preserves every staged pool, shader and spray setting")
	_check_water_shader_cache(staged.water_fx, synchronous.water_fx, standalone_water)
	var water_child_count: int = staged.water_fx.get_child_count()
	staged.water_fx.begin_setup(generator.WATER_Y)
	_check(staged.water_fx.setup_step() and staged.water_fx.get_child_count() == water_child_count,
		"repeating completed water setup is idempotent")
	staged.water_fx.entry_splash(Vector3(2, 0, 3), Vector3(1, -2, 0))
	staged.water_fx._process(0.1)
	_check(staged.water_fx._rings[0].active and staged.water_fx._foams[0].active \
		and staged.water_fx._sprays[0].emitting \
		and int(staged.water_fx._water_material.get_shader_parameter("ripple_count")) == 1,
		"completed staged water immediately renders splash, foam, spray and shader ripples")
	staged.water_fx.set_listener_swimming(true, 3.0)
	_check(staged.water_fx._loop_target_db > -60.0,
		"completed staged water has a ready local swimming audio bed")
	# All persistent registration/claim/rest checks above ran with entry effects
	# disabled. Silence the comparison world's duplicate signal subscriptions.
	synchronous.set_network_transient_effects_enabled(false)
	await _check_network_transient_gate(staged, net, generator)
	staged.free()
	synchronous.free()
	standalone_water.free()
	net.vehicle_spawn_definitions = original_definitions
	net.vehicle_rests = original_rests
	net.claimed_vehicles = original_vehicle_claims
	net.claimed_supply_chests = original_claims
	generator.setup(original_seed)
	print("WORLDSTAGEDBUILD_TIMINGS %s" % JSON.stringify(stage_timings))
	print("WORLDSTAGEDBUILDTEST %d/%d %s" % [passed, total, "PASS" if passed == total else "FAIL"])
	quit(0 if passed == total else 1)
