class_name CityWorld
extends Node3D

## Incremental visual and collision streamer for Crownreach.  The authoritative
## records remain in CityPlan; streamed nodes can be freely discarded.

const Plan = preload("res://scripts/city_plan.gd")
const Streets = preload("res://scripts/city_streets.gd")
const FACADE_SHADER = preload("res://scripts/city_facade.gdshader")

const STREAM_RADIUS := 2
const COLLISION_RADIUS := 1
const MAX_VISIBLE_BLOCKS := 25
const MAX_BLOCKS_PER_TICK := 1
const MAX_FAR_BLOCKS_PER_TICK := 1
const FAR_PRIORITY_RADIUS := 6
const MAX_SECTIONS_PER_BUILDING := 4
const SKYLINE_HEIGHT := 704.0
const MAX_STOREFRONT_LABELS_PER_BLOCK := 4
const MAX_NIGHT_LIGHTS := 12
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
var _shelter_positions: Dictionary = {}
var _district_colors: Array[Color] = []
var _far_road_surface: MeshInstance3D
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
var _night_update_timer := 0.0
var _night_factor := 0.0
var _night_lights: Array[OmniLight3D] = []
var _park_resources_initialized := false
var _damaged_buildings: Dictionary = {}
var _penthouse_host_id := ""
var _penthouse_floor_y := 0.0

var _unit_box: BoxMesh
var _shell_material: ShaderMaterial
var _roof_material: StandardMaterial3D
var _window_material: ShaderMaterial
var _door_material: StandardMaterial3D
var _curb_material: StandardMaterial3D
var _marking_material: StandardMaterial3D
var _lantern_material: ShaderMaterial
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
	_create_far_streets()
	_stream_root = Node3D.new()
	_stream_root.name = "StreamedBlocks"
	add_child(_stream_root)
	_build_village_properties()
	_create_night_lights()
	set_process(true)


func _exit_tree() -> void:
	Streets.release_resources()


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


## A premium suite occupies its real tower roof. Only that parcel's top eight
## metres are opened; every surrounding near/far building stays authoritative.
func set_building_damaged(id: String, damaged: bool) -> void:
	if _damaged_buildings.has(id)==damaged: return
	if damaged: _damaged_buildings[id]=true
	else: _damaged_buildings.erase(id)
	var record:=Plan.building(id)
	if record.is_empty():return
	var key:Vector2i=record.block
	if _loaded_blocks.has(key):
		var node:Node3D=_loaded_blocks[key].node
		node.hide();node.queue_free();_loaded_blocks.erase(key)
		_build_block(key)
	else:_restore_far_block(key)
	_refresh_collision_detail()


func set_penthouse_host(id: String, floor_y: float) -> void:
	if id == _penthouse_host_id and is_equal_approx(floor_y, _penthouse_floor_y):
		return
	var old_id := _penthouse_host_id
	_penthouse_host_id = id
	_penthouse_floor_y = floor_y
	var dirty: Dictionary = {}
	for host_id in [old_id, id]:
		var record := Plan.building(host_id)
		if not record.is_empty():
			dirty[record.block] = true
	for key in dirty:
		if _loaded_blocks.has(key):
			var node: Node3D = _loaded_blocks[key].node
			node.hide()
			node.queue_free()
			_loaded_blocks.erase(key)
			_build_block(key)
		else:
			_restore_far_block(key)
	_refresh_collision_detail()


func _clip_host_sections(record: Dictionary, sections: Array[Dictionary]) -> Array[Dictionary]:
	if _damaged_buildings.has(String(record.id)):
		for section in sections: section["disabled"] = true
		return sections
	if String(record.id) != _penthouse_host_id:
		return sections
	var cutoff := _penthouse_floor_y - Vector3(record.position).y - 0.24
	for section in sections:
		var size: Vector3 = section.size
		var offset: Vector3 = section.offset
		var bottom := offset.y - size.y * 0.5
		var top := minf(offset.y + size.y * 0.5, cutoff)
		section["disabled"] = top <= bottom
		size.y = maxf(0.001, top - bottom)
		offset.y = bottom + size.y * 0.5
		section.size = size
		section.offset = offset
	return sections


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
		return a.y * Plan.GRID_WIDTH + a.x < b.y * Plan.GRID_WIDTH + b.x
	)
	return result


func render_batch_count() -> int:
	var total := 1 if is_instance_valid(_far_road_surface) else 0
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
		"multimesh_resources": render_batch_count() - _plain_mesh_count(),
		"shared_mesh_resources": 5 + (3 if _park_resources_initialized else 0),
		"shared_material_resources": 11 + (3 if _park_resources_initialized else 0),
		"far_lod_batches": 1 if is_instance_valid(_far_instance) else 0,
		"far_lod_capacity": Plan.ESTIMATED_BUILDING_COUNT * MAX_SECTIONS_PER_BUILDING,
		"far_lod_instances": _far_next_instance,
		"far_lod_staged_blocks": _far_staged_blocks.size(),
		"far_lod_colliders": 0,
		"max_visible_blocks": MAX_VISIBLE_BLOCKS,
		"max_blocks_per_tick": MAX_BLOCKS_PER_TICK,
		"max_storefront_labels": MAX_VISIBLE_BLOCKS * MAX_STOREFRONT_LABELS_PER_BLOCK,
		"night_lights": _night_lights.size(),
	}


func stats() -> Dictionary:
	return node_budget_snapshot()


func _plain_mesh_count() -> int:
	var count := 1 if is_instance_valid(_far_road_surface) else 0
	for entry in _loaded_blocks.values():
		count += int(entry.get("plain_meshes", 1))
	return count


func shelter_position(anchor: Vector3) -> Vector3:
	if _shelter_positions.has(anchor):
		return _shelter_positions[anchor]
	if Plan.contains(Vector2(anchor.x, anchor.z)):
		# Shelters are six metres long along X. Seat them on the horizontal
		# sidewalk, with their 2.7 m depth wholly outside either carriageway.
		var closest_road := roundi((anchor.z - Plan.MIN_Z) / Plan.STREET_SPACING.y)
		for road_delta in [0, -1, 1, -2, 2]:
			var road_index := closest_road + int(road_delta)
			var road_z := Plan.MIN_Z + float(road_index) * Plan.STREET_SPACING.y
			var road_half := Plan.MAJOR_ROAD_HALF_WIDTH if posmod(road_index, 4) == 0 else Plan.LOCAL_ROAD_HALF_WIDTH
			for along in [18.0, -18.0, 26.0, -26.0, 0.0, 34.0, -34.0, 46.0, -46.0]:
				for side in [-1.0, 1.0]:
					var candidate := Vector3(anchor.x + along, anchor.y, road_z + side * (road_half + 1.5))
					if candidate.distance_to(anchor) < 17.0 or not _shelter_outside_road_lanes(candidate):
						continue
					if _shelter_site_clear(candidate):
						_shelter_positions[anchor] = candidate
						return candidate
	for offset in _SHELTER_OFFSETS:
		var candidate := anchor + offset
		if _shelter_site_clear(candidate) and (not Plan.contains(Vector2(candidate.x, candidate.z)) or _shelter_outside_road_lanes(candidate)):
			_shelter_positions[anchor] = candidate
			return candidate
	return anchor + Vector3(0.0, 0.0, 30.0)


func _shelter_outside_road_lanes(candidate: Vector3) -> bool:
	if candidate.x - 3.1 < Plan.MIN_X or candidate.x + 3.1 > Plan.MAX_X or candidate.z - 1.4 < Plan.MIN_Z or candidate.z + 1.4 > Plan.MAX_Z:
		return false
	for axis in range(2):
		var coordinate := candidate.x - Plan.MIN_X if axis == 0 else candidate.z - Plan.MIN_Z
		var nearest_road := roundi(coordinate / Plan.STREET_SPACING[axis])
		var road_half := Plan.MAJOR_ROAD_HALF_WIDTH if posmod(nearest_road, 4) == 0 else Plan.LOCAL_ROAD_HALF_WIDTH
		var extent := 3.1 if axis == 0 else 1.4
		if absf(coordinate - float(nearest_road) * Plan.STREET_SPACING[axis]) < road_half + extent:
			return false
	return true


func _process(delta: float) -> void:
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
	_night_update_timer -= delta
	if _night_update_timer <= 0.0:
		_night_update_timer = 0.25
		_update_night_lighting()


func _create_shared_resources() -> void:
	_unit_box = BoxMesh.new()
	_unit_box.size = Vector3.ONE

	_shell_material = ShaderMaterial.new()
	_shell_material.resource_name = "Crownreach glass limestone and steel facades"
	_shell_material.shader = FACADE_SHADER
	_shell_material.set_shader_parameter("district_power", PackedFloat32Array([1,1,1,1,1,1,1,1,1,1,1,1]))

	_roof_material = _material(Color("323944"), 0.86)
	_window_material = ShaderMaterial.new()
	_window_material.shader = preload("res://scripts/city_storefront.gdshader")
	_door_material = _material(Color("203138"), 0.22)
	_door_material.metallic = 0.6
	_curb_material = _material(Color("a7a49b"), 0.9)
	_marking_material = _material(Color("d5d0bd"), 0.83)
	_lantern_material = ShaderMaterial.new()
	_lantern_material.resource_name = "Crownreach individually coloured sign and lamp emission"
	_lantern_material.shader = preload("res://scripts/city_lights.gdshader")
	_landscape_material = _material(Color.WHITE, 0.92)
	_landscape_material.vertex_color_use_as_albedo = true


func _create_far_streets() -> void:
	# One shared metre-scale surface preserves the actual street network beneath
	# every distant building. Window views no longer lose the lit avenues at the
	# edge of the 25-block detailed streaming ring.
	Streets._resources()
	var mesh := PlaneMesh.new()
	mesh.size = Vector2(Plan.MAX_X - Plan.MIN_X, Plan.MAX_Z - Plan.MIN_Z)
	_far_road_surface = MeshInstance3D.new()
	_far_road_surface.name = "MunicipalStreetNetwork"
	_far_road_surface.mesh = mesh
	_far_road_surface.material_override = Streets._pavement_material
	_far_road_surface.position = Vector3((Plan.MIN_X+Plan.MAX_X)*.5, Plan.GROUND_Y+.012,(Plan.MIN_Z+Plan.MAX_Z)*.5)
	_far_road_surface.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_far_road_surface)


func _create_far_lod() -> void:
	_far_multimesh = MultiMesh.new()
	_far_multimesh.resource_name = "Crownreach staged distant silhouettes"
	_far_multimesh.transform_format = MultiMesh.TRANSFORM_3D
	_far_multimesh.use_colors = true
	_far_multimesh.use_custom_data = true
	_far_multimesh.mesh = _unit_box
	_far_multimesh.instance_count = Plan.ESTIMATED_BUILDING_COUNT * MAX_SECTIONS_PER_BUILDING
	_far_multimesh.visible_instance_count = 0
	_far_multimesh.custom_aabb = AABB(
		Vector3(Plan.MIN_X, Plan.GROUND_Y, Plan.MIN_Z),
		Vector3(Plan.MAX_X - Plan.MIN_X, SKYLINE_HEIGHT, Plan.MAX_Z - Plan.MIN_Z)
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

	while _far_fallback_cursor < Plan.TOTAL_BLOCKS:
		var linear_index := _far_fallback_cursor
		_far_fallback_cursor += 1
		var fallback_key := Vector2i(linear_index % Plan.GRID_WIDTH, linear_index / Plan.GRID_WIDTH)
		if _far_staged_blocks.has(fallback_key) or _desired_blocks.has(fallback_key):
			continue
		_stage_far_block(fallback_key)
		_last_far_staged_this_tick = 1
		return

	# The first pass leaves the currently detailed window unstaged.  Fill those
	# slots last and immediately hide them, so complete-city accounting reaches
	# all 2,496 blocks without ever drawing a far shell over detailed geometry.
	while _far_completion_cursor < Plan.TOTAL_BLOCKS:
		var linear_index := _far_completion_cursor
		_far_completion_cursor += 1
		var completion_key := Vector2i(linear_index % Plan.GRID_WIDTH, linear_index / Plan.GRID_WIDTH)
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
	if start + records.size() * MAX_SECTIONS_PER_BUILDING > _far_multimesh.instance_count:
		push_error("Crownreach far LOD exceeded its deterministic instance budget")
		return
	var hidden := _loaded_blocks.has(key)
	for record in records:
		var sections := _building_sections(record)
		for section_index in range(sections.size()):
			var section: Dictionary = sections[section_index]
			var transform := _hidden_far_transform() if hidden else _section_transform(record, section)
			_far_multimesh.set_instance_transform(_far_next_instance, transform)
			_far_multimesh.set_instance_color(_far_next_instance, _building_color(record))
			_far_multimesh.set_instance_custom_data(_far_next_instance, _facade_data(record, section_index))
			_far_next_instance += 1
	_far_staged_blocks[key] = {"start": start, "count": _far_next_instance - start}
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
	var next_index := int(slot.start)
	for record in Plan.block_buildings(key):
		for section in _building_sections(record):
			_far_multimesh.set_instance_transform(next_index, _section_transform(record, section))
			next_index += 1
	assert(next_index == int(slot.start) + int(slot.count), "Stable skyline section count")
	_far_hidden_blocks.erase(key)


func _section_transform(record: Dictionary, section: Dictionary, origin := Vector2.ZERO) -> Transform3D:
	if bool(section.get("disabled", false)):
		return _hidden_far_transform()
	var position: Vector3 = record.position
	return _box_transform(position + Vector3(section.offset) - Vector3(origin.x, 0.0, origin.y), section.size)


func _building_seed(record: Dictionary) -> int:
	return posmod(int(record.get("facade_seed", String(record.id).hash())), 100000)


func _building_color(record: Dictionary) -> Color:
	# Mineral/metal palettes, with only a trace of each ward's wayfinding colour.
	var seed := _building_seed(record)
	var families := [Color("8f897d"), Color("294859"), Color("66513d"), Color("465b5f")]
	var family := seed % 4
	if Vector3(record.size).y < 36.0:
		family = 0
	var result: Color = families[family]
	if Vector3(record.size).y < 36.0:
		var masonry := [Color("918573"),Color("795548"),Color("c0b7a4"),Color("60676b"),Color("927764")]
		result = masonry[posmod(seed / 13,masonry.size())]
	result = result.lerp(Color("c4bba6") if family == 0 else Color("91a2a3"), float((seed / 4) % 7) * 0.028)
	var district_id := int(record.district)
	if district_id >= 0 and district_id < _district_colors.size():
		result = result.lerp(_district_colors[district_id], 0.055)
	return result


func _facade_data(record: Dictionary, section_index: int) -> Color:
	var seed := _building_seed(record)
	var family := seed % 4
	if float(Vector3(record.size).y) < 36.0 or section_index == 0:
		family = 0
	var floor_height := 3.8 if family > 0 else 3.6
	return Color(float(seed) / 100000.0, float(family) / 3.0, floor_height / 8.0, float(clampi(int(record.district), 0, 11)) / 11.0)


func _building_sections(record: Dictionary) -> Array[Dictionary]:
	return _clip_host_sections(record,preload("res://scripts/city_massing.gd").sections(record))


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
	var shell_data: Array[Color] = []
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
		sign_colors,
		shell_data,
		landscape_transforms,
		landscape_colors
	)
	Streets.append_geometry(key, curb_transforms, marking_transforms, landscape_transforms, landscape_colors, roof_transforms, window_transforms, sign_transforms, sign_colors)
	_append_stop_geometry(key, center, curb_transforms, sign_transforms, sign_colors)
	if _is_lantern_block(key):
		_append_lantern_square_geometry(center, curb_transforms, sign_transforms, sign_colors)

	var batches := 0
	batches += _add_batch(block_root, "BuildingShells", shell_transforms, _shell_material, shell_colors, shell_data)
	batches += _add_batch(block_root, "Roofs", roof_transforms, _roof_material)
	batches += _add_batch(block_root, "Windows", window_transforms, _window_material)
	batches += _add_batch(block_root, "UsableDoors", door_transforms, _door_material)
	batches += _add_batch(block_root, "CurbsAndShelters", curb_transforms, _curb_material)
	batches += _add_batch(block_root, "RaisedRoadMarkings", marking_transforms, _marking_material)
	batches += _add_batch(block_root, "LanternSigns", sign_transforms, _lantern_material, sign_colors)
	batches += _add_batch(block_root, "StreetTrees", landscape_transforms, _landscape_material, landscape_colors)
	batches += Streets.add_surfaces(block_root, key)
	preload("res://scripts/city_showroom.gd").add_display(block_root,records,center)
	var park_ground_meshes := int(block_root.get_meta("park_ground_meshes", 0))
	_park_resources_initialized = _park_resources_initialized or park_ground_meshes > 0
	_loaded_blocks[key] = {
		"node": block_root,
		"batches": batches,
		"plain_meshes": 1 + park_ground_meshes,
		"collision_shapes": 0,
		"collision_body": null,
		"records": records,
	}
	_hide_far_block(key)
	_add_service_labels(block_root, records, center)
	_add_storefront_labels(block_root, records, center)
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
	sign_colors: Array[Color],
	shell_data: Array[Color],
	accents: Array[Transform3D] = [],
	accent_colors: Array[Color] = []
) -> void:
	for record in records:
		if _damaged_buildings.has(str(record.id)):continue
		var position: Vector3 = record.position
		var size: Vector3 = record.size
		var local_ground := position - Vector3(origin.x, 0.0, origin.y)
		var sections := _building_sections(record)
		for section_index in range(sections.size()):
			var section: Dictionary = sections[section_index]
			if bool(section.get("disabled", false)):
				continue
			var section_size: Vector3 = section.size
			var section_center := local_ground + Vector3(section.offset)
			shells.append(_section_transform(record, section, origin))
			shell_colors.append(_building_color(record))
			shell_data.append(_facade_data(record, section_index))
			# Metal coping and real corner piers articulate each setback. The
			# physical section contains these trims; nothing widens the parcel.
			var roof_y := section_center.y + section_size.y * 0.5 - 0.18
			for side in [-1.0, 1.0]:
				roofs.append(_box_transform(Vector3(section_center.x, roof_y, section_center.z + side * (section_size.z * 0.5 - 0.12)), Vector3(section_size.x, 0.36, 0.25)))
				roofs.append(_box_transform(Vector3(section_center.x + side * (section_size.x * 0.5 - 0.12), roof_y, section_center.z), Vector3(0.25, 0.36, section_size.z)))
			if section_index > 0 and section_index < 3:
				for x_side in [-1.0, 1.0]:
					for z_side in [-1.0, 1.0]:
						roofs.append(_box_transform(section_center + Vector3(x_side * (section_size.x * 0.5 - 0.12), 0.0, z_side * (section_size.z * 0.5 - 0.12)), Vector3(0.3, section_size.y, 0.3)))
			if section_index == 3:
				# Mechanical crown louvers are geometry at close range, enclosed
				# by the same crown collider and preserved in the far silhouette.
				var vent_rows := clampi(int(section_size.y / 1.6), 2, 8)
				for row in range(vent_rows):
					var vent_y := section_center.y - section_size.y * 0.5 + (float(row) + 0.5) * section_size.y / float(vent_rows)
					roofs.append(_box_transform(Vector3(section_center.x, vent_y, section_center.z + section_size.z * 0.5 - 0.03), Vector3(section_size.x * 0.84, 0.18, 0.12)))
					roofs.append(_box_transform(Vector3(section_center.x, vent_y, section_center.z - section_size.z * 0.5 + 0.03), Vector3(section_size.x * 0.84, 0.18, 0.12)))

		var door: Vector3 = record.door
		var facade := Vector2(door.x - position.x, door.z - position.z).normalized()
		var outward := Vector3(facade.x, 0.0, facade.y)
		var tangent := Vector3(facade.y, 0.0, -facade.x)
		var z_front := absf(facade.y) > 0.5
		var facade_half := size.z * 0.5 if z_front else size.x * 0.5
		var front := local_ground + outward * (facade_half + 0.045)
		var local_door := front + Vector3.UP * 1.8
		# Door interaction records sit outside the parcel. Render the actual
		# entrance flush to its wall, leaving the entire approach unobstructed.
		var door_size := Vector3(2.5, 3.6, 0.11) if z_front else Vector3(0.11, 3.6, 2.5)
		doors.append(_box_transform(local_door, door_size))
		for side in [-1.0, 1.0]:
			var frame_size := Vector3(0.12, 3.65, 0.15) if z_front else Vector3(0.15, 3.65, 0.12)
			roofs.append(_box_transform(local_door + tangent * side * 1.28, frame_size))
			var pane_size := Vector3(3.0, 2.9, 0.10) if z_front else Vector3(0.10, 2.9, 3.0)
			windows.append(_box_transform(front + tangent * side * 3.45 + Vector3.UP * 1.8, pane_size))
			var sill_size := Vector3(3.1, 0.14, 0.2) if z_front else Vector3(0.2, 0.14, 3.1)
			roofs.append(_box_transform(front + tangent * side * 3.45 + Vector3.UP * 0.38, sill_size))
		var center_mullion := Vector3(0.075, 3.6, 0.16) if z_front else Vector3(0.16, 3.6, 0.075)
		roofs.append(_box_transform(local_door + outward * 0.045, center_mullion))
		var awning_size := Vector3(7.3, 0.18, 1.8) if z_front else Vector3(1.8, 0.18, 7.3)
		roofs.append(_box_transform(front + outward * 0.7 + Vector3.UP * 3.85, awning_size))
		if _is_storefront(record):
			var fabric_colors := [Color("405e50"), Color("753f35"), Color("344d65"), Color("797054")]
			var fabric_color: Color = fabric_colors[_building_seed(record) % fabric_colors.size()]
			accents.append(_box_transform(front + outward * 0.7 + Vector3.UP * 3.96, awning_size))
			accent_colors.append(fabric_color)
			var valance_size := Vector3(7.3, 0.34, 0.14) if z_front else Vector3(0.14, 0.34, 7.3)
			accents.append(_box_transform(front + outward * 1.55 + Vector3.UP * 3.81, valance_size))
			accent_colors.append(fabric_color.darkened(0.12))
		if String(record.kind) in ["market", "restaurant", "clinic", "school", "depot", "warehouse", "workshop", "utility"]:
			var sign_size := Vector3(4.5, 0.75, 0.14) if z_front else Vector3(0.14, 0.75, 4.5)
			signs.append(_box_transform(front + outward * 0.045 + Vector3.UP * 4.65, sign_size))
			sign_colors.append(_neon_color(int(record.lot) + int(record.district)))
		if _is_lantern_block(Vector2i(record.block)) and size.y > 36.0:
			var sign_size := Vector3(0.8, 7.4, 0.15) if z_front else Vector3(0.15, 7.4, 0.8)
			signs.append(_box_transform(front + tangent * (size.x * 0.32 if z_front else size.z * 0.32) + Vector3.UP * 8.0, sign_size))
			sign_colors.append(_neon_color(int(record.lot)))


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
	var pylons := _lantern_pylon_positions()
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
	var shell_data: Array[Color] = []
	var roofs: Array[Transform3D] = []
	var windows: Array[Transform3D] = []
	var doors: Array[Transform3D] = []
	var furniture: Array[Transform3D] = []
	var signs: Array[Transform3D] = []
	var sign_colors: Array[Color] = []
	_append_buildings(
		Plan.canonical_properties(), Vector2.ZERO, shells, shell_colors,
		roofs, windows, doors, signs, sign_colors, shell_data
	)
	var village_stop: Dictionary = Plan.stops()[0]
	_append_shelter(shelter_position(village_stop.position), furniture, signs, sign_colors, -1)
	var batches := 0
	batches += _add_batch(_village_root, "VillageHomes", shells, _shell_material, shell_colors, shell_data)
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


func _is_storefront(record: Dictionary) -> bool:
	return not str(record.get("retail_type","")).is_empty() or String(record.kind)=="clinic"


func _storefront_name(record: Dictionary) -> String:
	var retail := preload("res://scripts/city_commerce.gd").name_for(record)
	if not retail.is_empty(): return retail
	var names: Array[String] = []
	match String(record.kind):
		"market": names = ["CORNER MARKET", "FRESH & LOCAL", "DAILY GOODS", "CITY GROCER"]
		"restaurant": names = ["CANOPY CAFE", "NIGHT OWL DINER", "CROWN COFFEE", "THE CORNER KITCHEN"]
		"workshop": names = ["HARDWARE & REPAIR", "THE TOOL SHOP", "MAKERS SUPPLY", "NEIGHBORHOOD REPAIR"]
		"clinic": names = ["COMMUNITY CLINIC", "HEALTH & CARE", "NEIGHBORHOOD CLINIC", "CITY MEDICAL"]
	return names[_building_seed(record) % names.size()] if not names.is_empty() else ""


func _add_storefront_labels(parent: Node3D, records: Array[Dictionary], origin: Vector2) -> void:
	var label_count := 0
	for record in records:
		if label_count >= MAX_STOREFRONT_LABELS_PER_BLOCK:
			break
		if not _is_storefront(record) or _service_names_by_building.has(String(record.id)):
			continue
		var position: Vector3 = record.position
		var size: Vector3 = record.size
		var door: Vector3 = record.door
		var facade := Vector2(door.x - position.x, door.z - position.z).normalized()
		var half := size.z * 0.5 if absf(facade.y) > 0.5 else size.x * 0.5
		var label := Label3D.new()
		label.name = "Storefront_%s" % String(record.id).replace("-", "_")
		label.text = _storefront_name(record)
		label.position = position - Vector3(origin.x, 0.0, origin.y) + Vector3(facade.x, 0.0, facade.y) * (half + 0.18) + Vector3.UP * 4.66
		label.rotation.y = atan2(facade.x, facade.y)
		label.font_size = 42
		label.pixel_size = _capped_label_pixel_size(label.text, label.font_size, 4.25, 0.012)
		label.modulate = Color("fff1ce")
		label.outline_modulate = Color("19211e")
		label.outline_size = 8
		label.billboard = BaseMaterial3D.BILLBOARD_DISABLED
		label.no_depth_test = false
		label.visibility_range_end = 110.0
		label.visibility_range_end_margin = 20.0
		label.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
		parent.add_child(label)
		label_count += 1


func _create_night_lights() -> void:
	for index in range(MAX_NIGHT_LIGHTS):
		var light := OmniLight3D.new()
		light.name = "NeighborhoodStoreLight%d" % index
		light.light_color = Color("ffdaa0") if index % 3 != 0 else Color("dcecff")
		light.omni_range = 33.0
		light.omni_attenuation = 1.25
		light.shadow_enabled = false
		light.visible = false
		add_child(light)
		_night_lights.append(light)


func _update_night_lighting() -> void:
	var daylight: Variant = _world.get("daylight_amount") if is_instance_valid(_world) else null
	_night_factor = 1.0 - clampf(float(daylight), 0.0, 1.0) if daylight != null else 0.0
	var supplies := PackedFloat32Array([1,1,1,1,1,1,1,1,1,1,1,1])
	var owner_frontier: Variant = _world.get("frontier") if is_instance_valid(_world) else null
	if is_instance_valid(owner_frontier):
		var rows: Array = []
		if bool(owner_frontier._online) and is_instance_valid(owner_frontier._network):
			rows = owner_frontier._network.city.cached_view.get("districts", [])
		elif owner_frontier.simulation:
			rows = owner_frontier.simulation.state.get("city", {}).get("districts", [])
		for row in rows:
			var district_id := int(row.get("id", -1))
			if district_id >= 0 and district_id < 12:
				supplies[district_id] = float(row.get("infrastructure", {}).get("power_ratio", 1.0))
	_shell_material.set_shader_parameter("district_power", supplies)
	Streets.set_night_factor(_night_factor)
	_shell_material.set_shader_parameter("night_factor", _night_factor)
	_window_material.set_shader_parameter("night_factor", _night_factor)
	_lantern_material.set_shader_parameter("night_factor", _night_factor)
	for light in _night_lights:
		light.visible = false
	if _night_factor < 0.02 or not _has_focus:
		return
	var candidates: Array[Vector3] = []
	for entry in _loaded_blocks.values():
		for record in Array(entry.records):
			if not _is_storefront(record):
				continue
			var position: Vector3 = record.position
			var door: Vector3 = record.door
			var outward := Vector3(door.x - position.x, 0.0, door.z - position.z).normalized()
			var candidate := door + outward * 0.9 + Vector3.UP * 4.6
			if Vector2(candidate.x - _focus.x, candidate.z - _focus.z).length_squared() < 19600.0:
				candidates.append(candidate)
	candidates.sort_custom(func(a: Vector3, b: Vector3) -> bool: return a.distance_squared_to(_focus) < b.distance_squared_to(_focus))
	for index in range(mini(candidates.size(), _night_lights.size())):
		var light := _night_lights[index]
		light.position = candidates[index]
		light.light_energy = 4.0 * _night_factor * supplies[Plan.district_for_block(Plan.world_to_block(Vector2(light.position.x,light.position.z)))]
		light.visible = true


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
	var positions := _lantern_pylon_positions()
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
		var sections := _building_sections(record)
		for section_index in range(sections.size()):
			var section: Dictionary = sections[section_index]
			if bool(section.get("disabled", false)):
				continue
			var transform := _section_transform(record, section, origin)
			_add_box_collision(body, "Building_%s_Section%d" % [String(record.id).replace("-", "_"), section_index], section.size, transform.origin)
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
	colors: Array[Color] = [],
	custom_data: Array[Color] = []
) -> int:
	if transforms.is_empty():
		return 0
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.use_colors = colors.size() == transforms.size()
	multimesh.use_custom_data = custom_data.size() == transforms.size()
	multimesh.mesh = _unit_box
	multimesh.instance_count = transforms.size()
	for index in range(transforms.size()):
		multimesh.set_instance_transform(index, transforms[index])
		if multimesh.use_custom_data:
			multimesh.set_instance_custom_data(index, custom_data[index])
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


func _lantern_pylon_positions() -> Array[Vector2]:
	return [
		Plan.CENTER + Vector2(-17.0, -17.0), Plan.CENTER + Vector2(17.0, -17.0),
		Plan.CENTER + Vector2(-17.0, 17.0), Plan.CENTER + Vector2(17.0, 17.0),
	]


func _is_lantern_block(key: Vector2i) -> bool:
	return key.x in [23, 24] and key.y in [23, 24]
