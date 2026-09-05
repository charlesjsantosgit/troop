class_name CityWorld
extends Node3D

## Incremental visual and collision streamer for Crownreach.  The authoritative
## records remain in CityPlan; streamed nodes can be freely discarded.

const Plan = preload("res://scripts/city_plan.gd")

const STREAM_RADIUS := 2
const COLLISION_RADIUS := 1
const MAX_VISIBLE_BLOCKS := 25
const MAX_BLOCKS_PER_TICK := 1
const MAX_FAR_BLOCKS_PER_TICK := 1
const FAR_PRIORITY_RADIUS := 6
const _SHELTER_OFFSETS: Array[Vector3] = [
	Vector3(18.0, 0.0, 18.0), Vector3(-18.0, 0.0, 18.0),
	Vector3(18.0, 0.0, -18.0), Vector3(-18.0, 0.0, -18.0),
	Vector3(24.0, 0.0, 0.0), Vector3(-24.0, 0.0, 0.0),
	Vector3(0.0, 0.0, 24.0), Vector3(0.0, 0.0, -24.0),
]

var _world: Node3D
var _stream_root: Node3D
var _village_root: Node3D
var _loaded_blocks: Dictionary = {}
var _desired_blocks: Dictionary = {}
var _build_queue: Array[Vector2i] = []
var _focus := Vector3.ZERO
var _focus_block := Vector2i(-1, -1)
var _has_focus := false
var _configured := false
var _last_built_this_tick := 0
var _village_collision_shapes := 0
var _service_names_by_building: Dictionary = {}
var _district_colors: Array[Color] = []
var _far_instance: MultiMeshInstance3D
var _far_multimesh: MultiMesh
var _far_staged_blocks: Dictionary = {}
var _far_hidden_blocks: Dictionary = {}
var _far_priority_queue: Array[Vector2i] = []
var _far_priority_set: Dictionary = {}
var _far_restore_queue: Array[Vector2i] = []
var _far_restore_set: Dictionary = {}
var _far_fallback_cursor := 0
var _far_completion_cursor := 0
var _far_next_instance := 0
var _last_far_staged_this_tick := 0

var _unit_box: BoxMesh
var _shell_material: StandardMaterial3D
var _roof_material: StandardMaterial3D
var _window_material: StandardMaterial3D
var _door_material: StandardMaterial3D
var _curb_material: StandardMaterial3D
var _marking_material: StandardMaterial3D
var _lantern_material: StandardMaterial3D
var _landscape_material: StandardMaterial3D


func configure(world: Node3D) -> void:
	if _configured:
		return
	_world = world
	_configured = true
	name = "CrownreachCityWorld"
	_create_shared_resources()
	for district_record in Plan.district_catalog():
		_district_colors.append(Color(district_record.color))
	for service_record in Plan.services():
		_service_names_by_building[String(service_record.building_id)] = String(service_record.name)
	_create_far_lod()
	_stream_root = Node3D.new()
	_stream_root.name = "StreamedBlocks"
	add_child(_stream_root)
	_build_village_properties()
	set_process(true)


func update_focus(position: Vector3) -> void:
	var next_focus_block := Plan.world_to_block(Vector2(position.x, position.z))
	if _has_focus and next_focus_block == _focus_block:
		_focus = position
		return
	_focus = position
	_focus_block = next_focus_block
	_has_focus = true
	var ordered := Plan.blocks_near(position, STREAM_RADIUS)
	if ordered.size() > MAX_VISIBLE_BLOCKS:
		ordered.resize(MAX_VISIBLE_BLOCKS)
	_desired_blocks.clear()
	for key in ordered:
		_desired_blocks[key] = true

	for key in _loaded_blocks.keys():
		if _desired_blocks.has(key):
			continue
		var entry: Dictionary = _loaded_blocks[key]
		var block_node: Node = entry.get("node")
		if is_instance_valid(block_node):
			block_node.queue_free()
		_loaded_blocks.erase(key)
		_queue_far_restore(key)

	_build_queue.clear()
	for key in ordered:
		if not _loaded_blocks.has(key):
			_build_queue.append(key)
	_prioritize_far_blocks()
	_refresh_collision_detail()


func visible_block_count() -> int:
	return _loaded_blocks.size()


func queued_block_count() -> int:
	return _build_queue.size()


func last_built_this_tick() -> int:
	return _last_built_this_tick


func last_far_staged_this_tick() -> int:
	return _last_far_staged_this_tick


func far_staged_block_count() -> int:
	return _far_staged_blocks.size()


func far_visible_instance_count() -> int:
	return _far_next_instance


func far_block_has_silhouette(key: Vector2i) -> bool:
	return _far_staged_blocks.has(key) and not _far_hidden_blocks.has(key)


func far_lod_bounds() -> AABB:
	return _far_multimesh.custom_aabb if _far_multimesh != null else AABB()


func loaded_block_keys() -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	for key in _loaded_blocks.keys():
		result.append(key)
	result.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return a.y * Plan.GRID_SIZE + a.x < b.y * Plan.GRID_SIZE + b.x
	)
	return result


func render_batch_count() -> int:
	var total := 0
	for entry in _loaded_blocks.values():
		total += int(entry.get("batches", 0))
	if is_instance_valid(_village_root):
		total += int(_village_root.get_meta("render_batches", 0))
	if is_instance_valid(_far_instance):
		total += 1
	return total


func collision_shape_count() -> int:
	var total := _village_collision_shapes
	for entry in _loaded_blocks.values():
		total += int(entry.get("collision_shapes", 0))
	return total


func visible_building_count() -> int:
	var total := 3
	for entry in _loaded_blocks.values():
		total += Array(entry.get("records", [])).size()
	return total


func node_budget_snapshot() -> Dictionary:
	return {
		"visible_blocks": visible_block_count(),
		"queued_blocks": queued_block_count(),
		"render_batches": render_batch_count(),
		"collision_shapes": collision_shape_count(),
		"building_colliders": collision_shape_count(),
		"visible_buildings": visible_building_count(),
		"conceptual_buildings": Plan.ESTIMATED_BUILDING_COUNT + 3,
		"multimesh_resources": render_batch_count(),
		"shared_mesh_resources": 1,
		"shared_material_resources": 8,
		"far_lod_batches": 1 if is_instance_valid(_far_instance) else 0,
		"far_lod_capacity": Plan.ESTIMATED_BUILDING_COUNT,
		"far_lod_instances": _far_next_instance,
		"far_lod_staged_blocks": _far_staged_blocks.size(),
		"far_lod_colliders": 0,
		"max_visible_blocks": MAX_VISIBLE_BLOCKS,
		"max_blocks_per_tick": MAX_BLOCKS_PER_TICK,
	}


func stats() -> Dictionary:
	return node_budget_snapshot()


func shelter_position(anchor: Vector3) -> Vector3:
	for offset in _SHELTER_OFFSETS:
		var candidate := anchor + offset
		if _shelter_site_clear(candidate):
			return candidate
	return anchor + Vector3(0.0, 0.0, 30.0)


func _process(_delta: float) -> void:
	_last_built_this_tick = 0
	_last_far_staged_this_tick = 0
	if not _configured:
		return
	while not _build_queue.is_empty() and _last_built_this_tick < MAX_BLOCKS_PER_TICK:
		var key: Vector2i = _build_queue.pop_front()
		if not _desired_blocks.has(key) or _loaded_blocks.has(key):
			continue
		_build_block(key)
		_last_built_this_tick += 1
	if _last_built_this_tick > 0:
		_refresh_collision_detail()
	_stage_one_far_block()


func _create_shared_resources() -> void:
	_unit_box = BoxMesh.new()
	_unit_box.size = Vector3.ONE

	_shell_material = StandardMaterial3D.new()
	_shell_material.resource_name = "Crownreach shared masonry"
	_shell_material.albedo_color = Color.WHITE
	_shell_material.vertex_color_use_as_albedo = true
	_shell_material.roughness = 0.78

	_roof_material = _material(Color("323944"), 0.86)
	_window_material = _material(Color("8dc8d9"), 0.28)
	_window_material.emission_enabled = true
	_window_material.emission = Color("457f9a")
	_window_material.emission_energy_multiplier = 1.35
	_door_material = _material(Color("51382d"), 0.72)
	_curb_material = _material(Color("a7a49b"), 0.9)
	_marking_material = _material(Color("e5c85e"), 0.68)
	_marking_material.emission_enabled = true
	_marking_material.emission = Color("6a5318")
	_marking_material.emission_energy_multiplier = 0.35
	_lantern_material = _material(Color("f08b3d"), 0.32)
	_lantern_material.vertex_color_use_as_albedo = true
	_lantern_material.emission_enabled = true
	_lantern_material.emission = Color("d45d32")
	_lantern_material.emission_energy_multiplier = 2.25
	_landscape_material = _material(Color.WHITE, 0.92)
	_landscape_material.vertex_color_use_as_albedo = true


func _create_far_lod() -> void:
	_far_multimesh = MultiMesh.new()
	_far_multimesh.resource_name = "Crownreach staged distant silhouettes"
	_far_multimesh.transform_format = MultiMesh.TRANSFORM_3D
	_far_multimesh.use_colors = true
	_far_multimesh.mesh = _unit_box
	_far_multimesh.instance_count = Plan.ESTIMATED_BUILDING_COUNT
	_far_multimesh.visible_instance_count = 0
	_far_multimesh.custom_aabb = AABB(
		Vector3(Plan.MIN_X, Plan.GROUND_Y, Plan.MIN_Z),
		Vector3(Plan.MAX_X - Plan.MIN_X, 128.0, Plan.MAX_Z - Plan.MIN_Z)
	)
	_far_instance = MultiMeshInstance3D.new()
	_far_instance.name = "DistantCitySilhouettes"
	_far_instance.multimesh = _far_multimesh
	_far_instance.material_override = _shell_material
	_far_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_far_instance.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	add_child(_far_instance)


func _prioritize_far_blocks() -> void:
	var ordered := Plan.blocks_near(_focus, FAR_PRIORITY_RADIUS)
	var merged: Array[Vector2i] = []
	var included: Dictionary = {}
	for key in ordered:
		if _desired_blocks.has(key) or _far_staged_blocks.has(key):
			continue
		merged.append(key)
		included[key] = true
	for key in _far_priority_queue:
		if included.has(key) or _far_staged_blocks.has(key):
			continue
		merged.append(key)
		included[key] = true
	_far_priority_queue = merged
	_far_priority_set = included


func _queue_far_restore(key: Vector2i) -> void:
	if not Plan.valid_block(key) or _far_restore_set.has(key):
		return
	_far_restore_queue.append(key)
	_far_restore_set[key] = true


func _stage_one_far_block() -> void:
	while not _far_restore_queue.is_empty():
		var restore_key: Vector2i = _far_restore_queue.pop_front()
		_far_restore_set.erase(restore_key)
		if _loaded_blocks.has(restore_key):
			continue
		if _far_staged_blocks.has(restore_key):
			_restore_far_block(restore_key)
		else:
			_stage_far_block(restore_key)
		_last_far_staged_this_tick = 1
		return

	while not _far_priority_queue.is_empty():
		var priority_key: Vector2i = _far_priority_queue.pop_front()
		_far_priority_set.erase(priority_key)
		if _far_staged_blocks.has(priority_key) or _desired_blocks.has(priority_key):
			continue
		_stage_far_block(priority_key)
		_last_far_staged_this_tick = 1
		return

	while _far_fallback_cursor < Plan.GRID_SIZE * Plan.GRID_SIZE:
		var linear_index := _far_fallback_cursor
		_far_fallback_cursor += 1
		var fallback_key := Vector2i(linear_index % Plan.GRID_SIZE, linear_index / Plan.GRID_SIZE)
		if _far_staged_blocks.has(fallback_key) or _desired_blocks.has(fallback_key):
			continue
		_stage_far_block(fallback_key)
		_last_far_staged_this_tick = 1
		return

	# The first pass leaves the currently detailed window unstaged.  Fill those
	# slots last and immediately hide them, so complete-city accounting reaches
	# all 2,304 blocks without ever drawing a far shell over detailed geometry.
	while _far_completion_cursor < Plan.GRID_SIZE * Plan.GRID_SIZE:
		var linear_index := _far_completion_cursor
		_far_completion_cursor += 1
		var completion_key := Vector2i(linear_index % Plan.GRID_SIZE, linear_index / Plan.GRID_SIZE)
		if _far_staged_blocks.has(completion_key):
			continue
		_stage_far_block(completion_key)
		_last_far_staged_this_tick = 1
		return


func _stage_far_block(key: Vector2i) -> void:
	if _far_staged_blocks.has(key):
		return
	var records := Plan.block_buildings(key)
	var start := _far_next_instance
	if start + records.size() > _far_multimesh.instance_count:
		push_error("Crownreach far LOD exceeded its deterministic instance budget")
		return
	var hidden := _loaded_blocks.has(key)
	for record in records:
		var transform := _hidden_far_transform() if hidden else _far_transform(record)
		_far_multimesh.set_instance_transform(_far_next_instance, transform)
		_far_multimesh.set_instance_color(_far_next_instance, _far_color(record))
		_far_next_instance += 1
	_far_staged_blocks[key] = {"start": start, "count": records.size()}
	if hidden:
		_far_hidden_blocks[key] = true
	_far_multimesh.visible_instance_count = _far_next_instance


func _hide_far_block(key: Vector2i) -> void:
	if not _far_staged_blocks.has(key) or _far_hidden_blocks.has(key):
		return
	var slot: Dictionary = _far_staged_blocks[key]
	for index in range(int(slot.start), int(slot.start) + int(slot.count)):
		_far_multimesh.set_instance_transform(index, _hidden_far_transform())
	_far_hidden_blocks[key] = true


func _restore_far_block(key: Vector2i) -> void:
	if not _far_staged_blocks.has(key) or _loaded_blocks.has(key):
		return
	var slot: Dictionary = _far_staged_blocks[key]
	var records := Plan.block_buildings(key)
	if records.size() != int(slot.count):
		push_error("Crownreach far LOD block count changed for %s" % key)
		return
	for offset in range(records.size()):
		_far_multimesh.set_instance_transform(int(slot.start) + offset, _far_transform(records[offset]))
	_far_hidden_blocks.erase(key)


func _far_transform(record: Dictionary) -> Transform3D:
	var position: Vector3 = record.position
	var size: Vector3 = record.size
	if int(record.floors) >= 9:
		size.x *= 0.76
		size.z *= 0.76
	return _box_transform(position + Vector3(0.0, size.y * 0.5, 0.0), size)


func _far_color(record: Dictionary) -> Color:
	var district_id := int(record.district)
	var base := Color("777d82") if district_id < 0 or district_id >= _district_colors.size() else _district_colors[district_id]
	return base.lerp(Color("87909a"), 0.22)


func _hidden_far_transform() -> Transform3D:
	return _box_transform(Vector3.ZERO, Vector3.ZERO)


func _material(color: Color, roughness: float) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = roughness
	return material


func _build_block(key: Vector2i) -> void:
	var center := Plan.block_center(key)
	var block_root := Node3D.new()
	block_root.name = "Block_%02d_%02d" % [key.x, key.y]
	block_root.position = Vector3(center.x, 0.0, center.y)
	_stream_root.add_child(block_root)

	var shell_transforms: Array[Transform3D] = []
	var shell_colors: Array[Color] = []
	var roof_transforms: Array[Transform3D] = []
	var window_transforms: Array[Transform3D] = []
	var door_transforms: Array[Transform3D] = []
	var curb_transforms: Array[Transform3D] = []
	var marking_transforms: Array[Transform3D] = []
	var sign_transforms: Array[Transform3D] = []
	var sign_colors: Array[Color] = []
	var landscape_transforms: Array[Transform3D] = []
	var landscape_colors: Array[Color] = []
	var records := Plan.block_buildings(key)
	_append_buildings(
		records,
		center,
		shell_transforms,
		shell_colors,
		roof_transforms,
		window_transforms,
		door_transforms,
		sign_transforms,
		sign_colors
	)
	_append_street_geometry(curb_transforms, marking_transforms, landscape_transforms, landscape_colors)
	_append_stop_geometry(key, center, curb_transforms, sign_transforms, sign_colors)
	if _is_lantern_block(key):
		_append_lantern_square_geometry(center, curb_transforms, sign_transforms, sign_colors)

	var batches := 0
	batches += _add_batch(block_root, "BuildingShells", shell_transforms, _shell_material, shell_colors)
	batches += _add_batch(block_root, "Roofs", roof_transforms, _roof_material)
	batches += _add_batch(block_root, "Windows", window_transforms, _window_material)
	batches += _add_batch(block_root, "UsableDoors", door_transforms, _door_material)
	batches += _add_batch(block_root, "CurbsAndShelters", curb_transforms, _curb_material)
	batches += _add_batch(block_root, "RaisedRoadMarkings", marking_transforms, _marking_material)
	batches += _add_batch(block_root, "LanternSigns", sign_transforms, _lantern_material, sign_colors)
	batches += _add_batch(block_root, "StreetTrees", landscape_transforms, _landscape_material, landscape_colors)
	_loaded_blocks[key] = {
		"node": block_root,
		"batches": batches,
		"collision_shapes": 0,
		"collision_body": null,
		"records": records,
	}
	_hide_far_block(key)
	_add_service_labels(block_root, records, center)
	if _is_lantern_block(key):
		_add_lantern_label(block_root, key, center)


func _append_buildings(
	records: Array[Dictionary],
	origin: Vector2,
	shells: Array[Transform3D],
	shell_colors: Array[Color],
	roofs: Array[Transform3D],
	windows: Array[Transform3D],
	doors: Array[Transform3D],
	signs: Array[Transform3D],
	sign_colors: Array[Color]
) -> void:
	for record in records:
		var position: Vector3 = record.position
		var size: Vector3 = record.size
		var local_ground := Vector3(position.x - origin.x, position.y, position.z - origin.y)
		var district_id := int(record.district)
		var base_color := Color("8a8178") if district_id < 0 or district_id >= _district_colors.size() else _district_colors[district_id]
		var color_shift := float(posmod(int(record.lot), 4)) * 0.055
		var masonry_color := base_color.lerp(Color.WHITE, 0.12 + color_shift)
		var roof_width := size.x
		var roof_depth := size.z
		if int(record.floors) >= 9:
			var podium_height := minf(14.4, size.y * 0.38)
			var upper_height := size.y - podium_height
			var upper_size := Vector3(size.x * 0.76, upper_height, size.z * 0.76)
			shells.append(_box_transform(
				local_ground + Vector3(0.0, podium_height * 0.5, 0.0),
				Vector3(size.x, podium_height, size.z)
			))
			shell_colors.append(masonry_color)
			shells.append(_box_transform(
				local_ground + Vector3(0.0, podium_height + upper_height * 0.5, 0.0),
				upper_size
			))
			shell_colors.append(masonry_color.lerp(Color.WHITE, 0.09))
			roof_width = upper_size.x
			roof_depth = upper_size.z
		else:
			shells.append(_box_transform(local_ground + Vector3(0.0, size.y * 0.5, 0.0), size))
			shell_colors.append(masonry_color)
		roofs.append(_box_transform(
			local_ground + Vector3(0.0, size.y + 0.3, 0.0),
			Vector3(roof_width + 1.2, 0.6, roof_depth + 1.2)
		))

		var door: Vector3 = record.door
		var local_door := Vector3(door.x - origin.x, door.y + 1.65, door.z - origin.y)
		var facade := Vector2(door.x - position.x, door.z - position.z).normalized()
		var door_size := Vector3(2.8, 3.3, 0.32) if absf(facade.y) > 0.5 else Vector3(0.32, 3.3, 2.8)
		var frame_position := local_door - Vector3(facade.x, 0.0, facade.y) * 0.04
		var frame_size := door_size + Vector3(0.55, 0.55, 0.08) if absf(facade.y) > 0.5 else door_size + Vector3(0.08, 0.55, 0.55)
		signs.append(_box_transform(frame_position, frame_size))
		sign_colors.append(Color("ffd16b"))
		doors.append(_box_transform(local_door, door_size))
		_append_windows(record, origin, windows)
		var awning_position := local_door + Vector3(0.0, 1.9, 0.0)
		awning_position.x += facade.x * 1.0
		awning_position.z += facade.y * 1.0
		var awning_size := Vector3(5.2, 0.28, 2.2) if absf(facade.y) > 0.5 else Vector3(2.2, 0.28, 5.2)
		roofs.append(_box_transform(awning_position, awning_size))
		if String(record.kind) in ["market", "restaurant", "clinic", "school", "depot", "warehouse", "workshop", "utility"]:
			var service_sign_position := local_door + Vector3(0.0, 3.1, 0.0)
			var service_sign_size := Vector3(4.5, 1.15, 0.22) if absf(facade.y) > 0.5 else Vector3(0.22, 1.15, 4.5)
			signs.append(_box_transform(service_sign_position, service_sign_size))
			sign_colors.append(_neon_color(int(record.lot) + int(record.district)))

		if _is_lantern_block(Vector2i(record.block)):
			var sign_position := local_ground + Vector3(0.0, minf(size.y - 3.0, 15.0), 0.0)
			var sign_size: Vector3
			if absf(facade.y) > 0.5:
				sign_position.z += facade.y * (size.z * 0.5 + 0.2)
				sign_size = Vector3(minf(size.x * 0.66, 28.0), 4.5, 0.35)
			else:
				sign_position.x += facade.x * (size.x * 0.5 + 0.2)
				sign_size = Vector3(0.35, 4.5, minf(size.z * 0.66, 28.0))
			signs.append(_box_transform(sign_position, sign_size))
			sign_colors.append(_neon_color(int(record.lot)))
			if int(record.floors) >= 9:
				var upper_sign_position := local_ground + Vector3(0.0, minf(size.y - 9.0, 34.0), 0.0)
				var upper_sign_size: Vector3
				if absf(facade.y) > 0.5:
					upper_sign_position.z += facade.y * (size.z * 0.38 + 0.22)
					upper_sign_size = Vector3(9.0, 13.0, 0.4)
				else:
					upper_sign_position.x += facade.x * (size.x * 0.38 + 0.22)
					upper_sign_size = Vector3(0.4, 13.0, 9.0)
				signs.append(_box_transform(upper_sign_position, upper_sign_size))
				sign_colors.append(_neon_color(int(record.lot) + 2))


func _append_windows(
	record: Dictionary,
	origin: Vector2,
	windows: Array[Transform3D]
) -> void:
	var position: Vector3 = record.position
	var size: Vector3 = record.size
	var door: Vector3 = record.door
	var door_facade := Vector2(door.x - position.x, door.z - position.z).normalized()
	var storefront_center := Vector3(position.x - origin.x, position.y + 2.25, position.z - origin.y)
	var storefront_size: Vector3
	if absf(door_facade.y) > 0.5:
		storefront_center.z += door_facade.y * (size.z * 0.5 + 0.09)
		storefront_size = Vector3(size.x * 0.56, 3.15, 0.18)
	else:
		storefront_center.x += door_facade.x * (size.x * 0.5 + 0.09)
		storefront_size = Vector3(0.18, 3.15, size.z * 0.56)
	windows.append(_box_transform(storefront_center, storefront_size))
	var floors := mini(int(record.floors), 18)
	for floor_index in range(1, floors):
		if floor_index > 9 and floor_index % 2 == 0:
			continue
		var inset_scale := 0.76 if int(record.floors) >= 9 and float(floor_index) * 3.6 >= 14.4 else 1.0
		var width := size.x * inset_scale
		var depth := size.z * inset_scale
		var window_y := position.y + float(floor_index) * 3.6 + 1.75
		var center_x := position.x - origin.x
		var center_z := position.z - origin.y
		var horizontal_band := Vector3(width * 0.55, 1.35, 0.16)
		var vertical_band := Vector3(0.16, 1.35, depth * 0.55)
		windows.append(_box_transform(Vector3(center_x, window_y, center_z - depth * 0.5 - 0.08), horizontal_band))
		windows.append(_box_transform(Vector3(center_x, window_y, center_z + depth * 0.5 + 0.08), horizontal_band))
		windows.append(_box_transform(Vector3(center_x - width * 0.5 - 0.08, window_y, center_z), vertical_band))
		windows.append(_box_transform(Vector3(center_x + width * 0.5 + 0.08, window_y, center_z), vertical_band))


func _append_street_geometry(
	curbs: Array[Transform3D],
	markings: Array[Transform3D],
	landscape: Array[Transform3D],
	landscape_colors: Array[Color]
) -> void:
	# Root terrain owns the road surface.  These are only narrow raised curbs and
	# paint, aligned to its 120 m subdivisions and 480 m arterials.
	for road in [-120.0, 0.0, 120.0]:
		for side in [-10.0, 10.0]:
			curbs.append(_box_transform(Vector3(road + side, Plan.GROUND_Y + 0.11, 0.0), Vector3(0.32, 0.22, 456.0)))
			curbs.append(_box_transform(Vector3(0.0, Plan.GROUND_Y + 0.11, road + side), Vector3(456.0, 0.22, 0.32)))
	for boundary in [-223.0, 223.0]:
		curbs.append(_box_transform(Vector3(boundary, Plan.GROUND_Y + 0.11, 0.0), Vector3(0.34, 0.22, 456.0)))
		curbs.append(_box_transform(Vector3(0.0, Plan.GROUND_Y + 0.11, boundary), Vector3(456.0, 0.22, 0.34)))
	for road in [-240.0, -120.0, 0.0, 120.0]:
		for step in range(8):
			var offset := -210.0 + float(step) * 60.0
			markings.append(_box_transform(Vector3(road, Plan.GROUND_Y + 0.035, offset), Vector3(0.24, 0.07, 22.0)))
			markings.append(_box_transform(Vector3(offset, Plan.GROUND_Y + 0.035, road), Vector3(22.0, 0.07, 0.24)))
	# Trees sit beside parcel fronts, clear of the crowd's 12 m corner loops and
	# the vehicle lane.  Keeping them away from cell corners also preserves sight
	# lines at every intersection.
	for tree_position in [
		Vector2(-225.0, -180.0), Vector2(-135.0, -60.0),
		Vector2(-105.0, 60.0), Vector2(-15.0, 180.0),
		Vector2(15.0, -180.0), Vector2(105.0, -60.0),
		Vector2(135.0, 60.0), Vector2(225.0, 180.0),
	]:
		landscape.append(_box_transform(Vector3(tree_position.x, Plan.GROUND_Y + 2.2, tree_position.y), Vector3(0.55, 4.4, 0.55)))
		landscape_colors.append(Color("67503a"))
		landscape.append(_box_transform(Vector3(tree_position.x, Plan.GROUND_Y + 5.1, tree_position.y), Vector3(2.8, 3.2, 2.8)))
		landscape_colors.append(Color("4f7654"))


func _append_stop_geometry(
	key: Vector2i,
	origin: Vector2,
	furniture: Array[Transform3D],
	signs: Array[Transform3D],
	sign_colors: Array[Color]
) -> void:
	for stop in Plan.stops():
		var position: Vector3 = stop.position
		if Plan.world_to_block(Vector2(position.x, position.z)) != key:
			continue
		var shelter_world := shelter_position(position)
		var local := Vector3(shelter_world.x - origin.x, shelter_world.y, shelter_world.z - origin.y)
		_append_shelter(local, furniture, signs, sign_colors, int(stop.district))


func _append_shelter(
	position: Vector3,
	furniture: Array[Transform3D],
	signs: Array[Transform3D],
	sign_colors: Array[Color],
	color_seed: int
) -> void:
	furniture.append(_box_transform(position + Vector3(2.5, 1.8, 0.0), Vector3(0.28, 3.6, 0.28)))
	furniture.append(_box_transform(position + Vector3(0.0, 3.15, 0.0), Vector3(6.0, 0.24, 2.7)))
	furniture.append(_box_transform(position + Vector3(0.0, 0.55, 0.5), Vector3(3.2, 0.7, 0.75)))
	signs.append(_box_transform(position + Vector3(2.5, 2.75, 0.0), Vector3(1.3, 1.25, 0.18)))
	sign_colors.append(_neon_color(color_seed))


func _shelter_site_clear(candidate: Vector3) -> bool:
	if Plan.contains(Vector2(candidate.x, candidate.z)):
		for key in Plan.blocks_near(candidate, 1):
			for record in Plan.block_buildings(key):
				if _shelter_overlaps_building(candidate, record):
					return false
	for record in Plan.canonical_properties():
		if _shelter_overlaps_building(candidate, record):
			return false
	return true


func _shelter_overlaps_building(candidate: Vector3, record: Dictionary) -> bool:
	var position: Vector3 = record.position
	var size: Vector3 = record.size
	if absf(candidate.x - position.x) < size.x * 0.5 + 4.0 \
			and absf(candidate.z - position.z) < size.z * 0.5 + 2.3:
		return true
	var door: Vector3 = record.door
	return Vector2(candidate.x, candidate.z).distance_to(Vector2(door.x, door.z)) < 6.0


func _append_lantern_square_geometry(
	origin: Vector2,
	furniture: Array[Transform3D],
	signs: Array[Transform3D],
	sign_colors: Array[Color]
) -> void:
	var pylons := [
		Vector2(14308.0, -92.0), Vector2(14492.0, -92.0),
		Vector2(14308.0, 92.0), Vector2(14492.0, 92.0),
	]
	for index in range(pylons.size()):
		var world_position: Vector2 = pylons[index]
		if Plan.world_to_block(world_position) != Plan.world_to_block(origin):
			continue
		var local := Vector3(world_position.x - origin.x, Plan.GROUND_Y, world_position.y - origin.y)
		furniture.append(_box_transform(local + Vector3(0.0, 5.0, 0.0), Vector3(0.8, 10.0, 0.8)))
		signs.append(_box_transform(local + Vector3(0.0, 9.0, 0.0), Vector3(7.0, 3.5, 0.45)))
		sign_colors.append(_neon_color(index + 2))


func _build_village_properties() -> void:
	_village_root = Node3D.new()
	_village_root.name = "CanonicalVillageProperties"
	add_child(_village_root)
	var shells: Array[Transform3D] = []
	var shell_colors: Array[Color] = []
	var roofs: Array[Transform3D] = []
	var windows: Array[Transform3D] = []
	var doors: Array[Transform3D] = []
	var furniture: Array[Transform3D] = []
	var signs: Array[Transform3D] = []
	var sign_colors: Array[Color] = []
	_append_buildings(
		Plan.canonical_properties(), Vector2.ZERO, shells, shell_colors,
		roofs, windows, doors, signs, sign_colors
	)
	var village_stop: Dictionary = Plan.stops()[0]
	_append_shelter(shelter_position(village_stop.position), furniture, signs, sign_colors, -1)
	var batches := 0
	batches += _add_batch(_village_root, "VillageHomes", shells, _shell_material, shell_colors)
	batches += _add_batch(_village_root, "VillageRoofs", roofs, _roof_material)
	batches += _add_batch(_village_root, "VillageWindows", windows, _window_material)
	batches += _add_batch(_village_root, "VillageDoors", doors, _door_material)
	batches += _add_batch(_village_root, "VillageBusShelter", furniture, _curb_material)
	batches += _add_batch(_village_root, "VillageSigns", signs, _lantern_material, sign_colors)
	_village_root.set_meta("render_batches", batches)
	_add_service_labels(_village_root, Plan.canonical_properties(), Vector2.ZERO)
	var collision_body := _collision_body_for(Plan.canonical_properties(), Vector2.ZERO, "VillagePropertyCollision")
	_village_root.add_child(collision_body)
	_village_collision_shapes = collision_body.get_child_count()


func _add_service_labels(parent: Node3D, records: Array[Dictionary], origin: Vector2) -> void:
	for record in records:
		var id := String(record.id)
		if not _service_names_by_building.has(id):
			continue
		var door: Vector3 = record.door
		var building_position: Vector3 = record.position
		var facade := Vector2(door.x - building_position.x, door.z - building_position.z).normalized()
		var label := Label3D.new()
		label.name = "ServiceLabel_%s" % id.replace("-", "_")
		label.text = String(_service_names_by_building[id]).to_upper()
		label.position = Vector3(
			door.x - origin.x + facade.x * 0.24,
			door.y + 4.8,
			door.z - origin.y + facade.y * 0.24
		)
		label.font_size = 32
		label.pixel_size = _capped_label_pixel_size(label.text, label.font_size, 4.0, 0.006)
		label.modulate = Color("ffe6a8")
		label.outline_modulate = Color(0.03, 0.04, 0.05, 0.96)
		label.outline_size = 7
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.fixed_size = false
		label.no_depth_test = false
		label.visibility_range_begin = 2.0
		label.visibility_range_begin_margin = 0.8
		label.visibility_range_end = 55.0
		label.visibility_range_end_margin = 12.0
		label.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
		parent.add_child(label)


func _add_lantern_label(parent: Node3D, key: Vector2i, origin: Vector2) -> void:
	var index := (key.y - 23) * 2 + key.x - 23
	var titles := ["LANTERN", "TRANSIT", "LIGHTWORKS", "MARKET"]
	var positions := [
		Vector2(14308.0, -92.0), Vector2(14492.0, -92.0),
		Vector2(14308.0, 92.0), Vector2(14492.0, 92.0),
	]
	var label := Label3D.new()
	label.name = "LanternWayfinding"
	label.text = titles[index]
	label.position = Vector3(positions[index].x - origin.x, Plan.GROUND_Y + 9.0, positions[index].y - origin.y)
	label.position.z += 0.24 if index < 2 else -0.24
	label.font_size = 48
	label.pixel_size = _capped_label_pixel_size(label.text, label.font_size, 6.2, 0.02)
	label.modulate = _neon_color(index)
	label.outline_modulate = Color(0.02, 0.025, 0.04, 0.98)
	label.outline_size = 8
	label.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	label.rotation.y = 0.0 if index < 2 else PI
	label.fixed_size = false
	label.no_depth_test = false
	label.visibility_range_end = 210.0
	label.visibility_range_end_margin = 30.0
	label.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	parent.add_child(label)


func _capped_label_pixel_size(text: String, font_size: int, max_width: float, preferred: float) -> float:
	var estimated_pixels := maxf(1.0, float(text.length() * font_size) * 0.58)
	return minf(preferred, max_width / estimated_pixels)


func _refresh_collision_detail() -> void:
	if not _configured:
		return
	var near: Dictionary = {}
	for key in Plan.blocks_near(_focus, COLLISION_RADIUS):
		near[key] = true
	for key in _loaded_blocks.keys():
		var entry: Dictionary = _loaded_blocks[key]
		var body: StaticBody3D = entry.get("collision_body")
		if near.has(key) and not is_instance_valid(body):
			body = _collision_body_for(entry.records, Plan.block_center(key), "DetailedCollision")
			var block_node: Node3D = entry.node
			block_node.add_child(body)
			entry["collision_body"] = body
			entry["collision_shapes"] = body.get_child_count()
		elif not near.has(key) and is_instance_valid(body):
			body.queue_free()
			entry["collision_body"] = null
			entry["collision_shapes"] = 0
		_loaded_blocks[key] = entry


func _collision_body_for(records: Array[Dictionary], origin: Vector2, body_name: String) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = body_name
	body.collision_layer = 1
	body.collision_mask = 0
	for record in records:
		var position: Vector3 = record.position
		var size: Vector3 = record.size
		var local_ground := Vector3(position.x - origin.x, position.y, position.z - origin.y)
		var collision_name := "Building_%s" % String(record.id).replace("-", "_")
		if int(record.floors) >= 9:
			var podium_height := minf(14.4, size.y * 0.38)
			var upper_height := size.y - podium_height
			_add_box_collision(
				body, collision_name + "_Podium",
				Vector3(size.x, podium_height, size.z),
				local_ground + Vector3(0.0, podium_height * 0.5, 0.0)
			)
			_add_box_collision(
				body, collision_name + "_Upper",
				Vector3(size.x * 0.76, upper_height, size.z * 0.76),
				local_ground + Vector3(0.0, podium_height + upper_height * 0.5, 0.0)
			)
		else:
			_add_box_collision(
				body, collision_name, size,
				local_ground + Vector3(0.0, size.y * 0.5, 0.0)
			)
	return body


func _add_box_collision(parent: StaticBody3D, shape_name: String, size: Vector3, position: Vector3) -> void:
	var shape := BoxShape3D.new()
	shape.size = size
	var collision := CollisionShape3D.new()
	collision.name = shape_name
	collision.shape = shape
	collision.position = position
	parent.add_child(collision)


func _add_batch(
	parent: Node3D,
	batch_name: String,
	transforms: Array[Transform3D],
	material: Material,
	colors: Array[Color] = []
) -> int:
	if transforms.is_empty():
		return 0
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.use_colors = colors.size() == transforms.size()
	multimesh.mesh = _unit_box
	multimesh.instance_count = transforms.size()
	for index in range(transforms.size()):
		multimesh.set_instance_transform(index, transforms[index])
		if multimesh.use_colors:
			multimesh.set_instance_color(index, colors[index])
	var instance := MultiMeshInstance3D.new()
	instance.name = batch_name
	instance.multimesh = multimesh
	instance.material_override = material
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	parent.add_child(instance)
	return 1


func _box_transform(position: Vector3, size: Vector3) -> Transform3D:
	return Transform3D(Basis().scaled(size), position)


func _neon_color(seed: int) -> Color:
	var colors := [Color("ff843d"), Color("60d2ff"), Color("ef5ba1"), Color("ffe274"), Color("8bef87")]
	return colors[posmod(seed, colors.size())]


func _is_lantern_block(key: Vector2i) -> bool:
	return key.x in [23, 24] and key.y in [23, 24]
