extends SceneTree
## Headless-only shutdown diagnostic; this is not a renderer performance test.
##   godot --headless --path . --script res://tests/headlessparticleshutdownprobe.gd -- 6
## VehicleExhaust is byte-identical to v0.4.5 (Git blob
## 6ab545419eae39f6566e5264a52e7c18911433d8). On official Godot 4.7
## 5b4e0cb0f, ordinary repeated creation/freeing produced 1, 2, or 3 raw
## RendererDummy::MaterialStorage::DummyShader RIDs at ENGINE EXIT despite no
## surviving scene/material resources. Counts vary with lifecycle/frame pacing;
## 3 is an observed diagnostic, not a proven engine-wide upper bound: broader
## Resource-property tracking below also produced 4 and 5 on repeat runs. This
## fixture neither suppresses shutdown errors nor changes the full-join runner's
## bounded exception; it asserts only complete ownership/resource cleanup.

const MAX_CYCLES := 6
const FLUSH_FRAMES := 6

var _resource_refs: Dictionary = {}
var _node_refs: Array[WeakRef] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	if DisplayServer.get_name() != "headless" or args.size() > 1 \
			or (not args.is_empty() and not args[0].is_valid_int()):
		push_error("HEADLESSPARTICLESHUTDOWNPROBE requires --headless and optional cycles 1..6")
		quit(1)
		return
	var cycles := int(args[0]) if not args.is_empty() else MAX_CYCLES
	if cycles < 1 or cycles > MAX_CYCLES:
		push_error("HEADLESSPARTICLESHUTDOWNPROBE cycles must be 1..6")
		quit(1)
		return
	var exhaust_script: Script = load("res://scripts/vehicle_exhaust.gd")
	for cycle in range(cycles):
		var holder := _create_cycle(exhaust_script)
		for frame in range(FLUSH_FRAMES):
			await process_frame
		holder.free()
		for frame in range(FLUSH_FRAMES):
			await process_frame
	# The process is about to exit, so release even the intentionally shared
	# exhaust caches. Never perform this diagnostic inside a live game session.
	exhaust_script._mesh_cache.clear()
	exhaust_script._ramp_cache.clear()
	exhaust_script._scale_curve_cache.clear()
	exhaust_script._soft_particle_texture = null
	for frame in range(FLUSH_FRAMES):
		await process_frame
	var resources_alive := 0
	var materials_alive := 0
	var materials_tracked := 0
	for entry in _resource_refs.values():
		materials_tracked += int(entry.material)
		if entry.reference.get_ref() != null:
			resources_alive += 1
			materials_alive += int(entry.material)
	var nodes_alive := 0
	for reference in _node_refs:
		nodes_alive += int(reference.get_ref() != null)
	var passed := materials_tracked >= cycles * 4 \
		and resources_alive == 0 and materials_alive == 0 and nodes_alive == 0
	print("HEADLESSPARTICLESHUTDOWNPROBE %s cycles=%d tracked_resources=%d tracked_materials=%d surviving_resources=%d surviving_materials=%d surviving_nodes=%d" % [
		"PASS" if passed else "FAIL", cycles, _resource_refs.size(),
		materials_tracked, resources_alive, materials_alive, nodes_alive])
	quit(0 if passed else 1)


func _create_cycle(exhaust_script: Script) -> Node3D:
	var holder := Node3D.new()
	root.add_child(holder)
	_node_refs.append(weakref(holder))
	for profile in range(4):
		var exhaust = exhaust_script.new()
		holder.add_child(exhaust)
		exhaust.setup(profile, Vector3(0, 0, -1))
		_node_refs.append(weakref(exhaust))
		_node_refs.append(weakref(exhaust.particles))
		_track_resource(exhaust._process_material)
		_track_resource(exhaust.particles.draw_pass_1)
	return holder


func _track_resource(resource: Resource) -> void:
	if resource == null or resource is Script \
			or _resource_refs.has(resource.get_instance_id()):
		return
	_resource_refs[resource.get_instance_id()] = {
		"reference": weakref(resource), "material": resource is Material,
	}
	# Follow only stored Resource-valued properties (mesh materials, textures,
	# gradients and curves). Keep weak references, never extend their lifetime.
	for property in resource.get_property_list():
		if property.name == "script" \
				or (int(property.usage) & PROPERTY_USAGE_STORAGE) == 0:
			continue
		var value: Variant = resource.get(property.name)
		if value is Resource:
			_track_resource(value)
