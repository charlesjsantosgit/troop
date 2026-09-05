class_name Minimap
extends Control
## Xaero-style satellite minimap. Tiles are baked on the CPU straight from the
## deterministic generator (height → ground color + hillshade + depth-tinted
## water), so the map is a true top-down "satellite" of the actual world with
## zero extra render passes. Baking is spread across frames (a few rows per
## tick), tiles cache per zoom tier with LRU eviction, and the view auto-zooms
## out with player altitude. M cycles size, [ and ] zoom manually.

const TILE_PX := 96
const TIER_METERS_PER_PX := [4.0, 16.0, 64.0]
const ROWS_PER_FRAME := 24
const MOON_TIER_METERS_PER_PX := [1.5, 4.0, 8.0]
const MOON_ROWS_PER_FRAME := 3
const BAKE_TIME_BUDGET_USEC := 1500
const MOON_BAKE_TIME_BUDGET_USEC := BAKE_TIME_BUDGET_USEC
const BAKE_CHUNK_PIXELS := 8
const PREVIEW_BLOCK_PX := 8
const PREVIEW_GRID_PX := 12
const PREVIEW_SAMPLES := PREVIEW_GRID_PX * PREVIEW_GRID_PX
const MOON_CHART_REANCHOR_ANGLE := 0.45
# A large view near a tier boundary can expose more than 70 tiles while
# diagonal. Keeping 128 retains a complete heading sweep without unbounded
# memory growth or evicting a tile that is still visible.
const TILES_PER_TIER := 128
const SIZE_SMALL := 180.0
const SIZE_LARGE := 300.0
const VEHICLE_HEADING_MIN_LENGTH_SQUARED := 0.0004

var world: Node3D
var mode := 0            # 0 small · 1 large · 2 hidden
var zoom_multiplier := 1.0
var _tiles: Array = [{}, {}, {}]   # per tier: Vector2i -> tile dict
var _bake_queue: Array = []        # [tier, key] pairs awaiting rows
var _baked_seed := -1
var _font: Font
var _last_required_tier := -1
var _last_required_keys: Dictionary = {}
var _last_baked_rows := 0
var _last_baked_pixels := 0
var _last_preview_samples := 0
var _last_bake_usec := 0
var _last_bake_chunk_usec := 0
var _last_texture_uploads := 0
var _map_realm := Net.PlayerRealm.EARTH
var _moon: MoonWorld
var _moon_chart_up := Vector3.UP
var _moon_chart_east := Vector3.RIGHT
var _moon_chart_south := Vector3.BACK
var _moon_chart_revision := 0
var _moon_landmarks: Array[Dictionary] = []
var _drawn_label_rects: Array[Rect2] = []
## Heading-up is deliberately a local-driver presentation state. The last
## usable ground-plane heading survives a vertical jet loop, where projecting
## the aircraft nose onto XZ has no meaningful direction.
var _heading_vehicle_id := 0
var _last_vehicle_heading := Vector2.UP


func configure(owner_world: Node3D) -> void:
	world = owner_world


func _ready() -> void:
	_font = ThemeDB.fallback_font
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var settings := get_node_or_null("/root/Settings")
	if settings:
		mode = clampi(int(settings.get("minimap_mode")), 0, 2)
		zoom_multiplier = clampf(float(settings.get("minimap_zoom")), 0.4, 2.6)
	_apply_size()


func cycle_size() -> void:
	mode = (mode + 1) % 3
	_apply_size()
	_persist()


func zoom_step(direction: int) -> void:
	zoom_multiplier = clampf(zoom_multiplier * (1.25 if direction > 0 else 0.8),
		0.4, 2.6)
	_persist()


func _persist() -> void:
	var settings := get_node_or_null("/root/Settings")
	if settings and settings.has_method("set_minimap_prefs"):
		settings.set_minimap_prefs(mode, zoom_multiplier)


func map_px() -> float:
	return SIZE_LARGE if mode == 1 else SIZE_SMALL


func _apply_size() -> void:
	visible = mode != 2
	custom_minimum_size = Vector2(map_px(), map_px() + 16.0)
	size = custom_minimum_size


func _player() -> Node3D:
	return world.local_player if world and world.get("local_player") else null


func map_realm() -> int:
	return _map_realm


func map_cache_key() -> String:
	return "%d:%d:%d" % [_map_realm, _baked_seed,
		_moon_chart_revision if _map_realm == Net.PlayerRealm.MOON else 0]


func preview_ready() -> bool:
	if _last_required_tier < 0 or _last_required_keys.is_empty():
		return false
	for key in _last_required_keys:
		var tile: Dictionary = _tiles[_last_required_tier].get(key, {})
		if int(tile.get("preview_cursor", 0)) < PREVIEW_SAMPLES:
			return false
	return true


func _reset_tiles() -> void:
	_tiles = [{}, {}, {}]
	_bake_queue.clear()
	_last_required_tier = -1
	_last_required_keys.clear()
	_last_baked_rows = 0
	_last_baked_pixels = 0
	_last_preview_samples = 0
	_last_texture_uploads = 0


func _sync_map_context() -> bool:
	var realm := Net.player_realm()
	if realm not in [Net.PlayerRealm.EARTH, Net.PlayerRealm.MOON]:
		return false
	var source_moon: MoonWorld
	var seed_value := Gen.world_seed
	var reanchor := false
	if realm == Net.PlayerRealm.MOON:
		var manager: ExpeditionManager = world.get("expedition_manager")
		if not is_instance_valid(manager) or not is_instance_valid(manager.moon_world):
			return false
		source_moon = manager.moon_world
		seed_value = source_moon.moon_seed
		var direction := (source_moon.to_local(_player().global_position)
			- MoonWorld.PLAYABLE_CENTER).normalized()
		if direction.is_zero_approx():
			return false
		reanchor = source_moon != _moon or _map_realm != realm \
			or seed_value != _baked_seed \
			or _moon_chart_up.dot(direction) < cos(MOON_CHART_REANCHOR_ANGLE)
		if reanchor:
			if source_moon == _moon and _map_realm == realm:
				# Carry the chart's orientation over the sphere. This remains stable
				# at poles, where choosing world north afresh would spin the map.
				var transport := Quaternion(_moon_chart_up, direction)
				_moon_chart_east = (transport * _moon_chart_east).slide(direction).normalized()
			else:
				_moon_chart_east = MoonWorld.surface_basis(direction).x
			_moon_chart_up = direction
			_moon_chart_south = _moon_chart_east.cross(direction).normalized()
			_moon_chart_revision += 1
	if realm != _map_realm or seed_value != _baked_seed or reanchor:
		_reset_tiles()
		_map_realm = realm
		_baked_seed = seed_value
		_moon = source_moon
		_cache_moon_landmarks()
	return true


## Azimuthal coordinates preserve surface distance from a radial chart origin.
## Re-anchoring before half a hemisphere keeps the visible chart well behaved.
func moon_map_coordinates(world_position: Vector3) -> Vector2:
	if not is_instance_valid(_moon):
		return Vector2.ZERO
	var direction := (_moon.to_local(world_position) - MoonWorld.PLAYABLE_CENTER).normalized()
	var dot_up := clampf(_moon_chart_up.dot(direction), -1.0, 1.0)
	var tangent := direction - _moon_chart_up * dot_up
	if tangent.length_squared() < 0.00000001:
		return Vector2(PI * MoonWorld.PLAYABLE_RADIUS_METERS, 0.0) if dot_up < 0.0 else Vector2.ZERO
	# atan2 retains small walking distances that acos loses when a float32
	# near-parallel dot product rounds to one.
	var angle := atan2(tangent.length(), dot_up)
	var distance := angle * MoonWorld.PLAYABLE_RADIUS_METERS
	tangent = tangent.normalized()
	return Vector2(tangent.dot(_moon_chart_east), tangent.dot(_moon_chart_south)) * distance


func moon_direction_at(chart_position: Vector2) -> Vector3:
	var distance := chart_position.length()
	if distance < 0.000001:
		return _moon_chart_up
	var angle := distance / MoonWorld.PLAYABLE_RADIUS_METERS
	var tangent := (_moon_chart_east * chart_position.x
		+ _moon_chart_south * chart_position.y) / distance
	return (_moon_chart_up * cos(angle) + tangent * sin(angle)).normalized()


func map_height_at(chart_position: Vector2) -> float:
	if _map_realm == Net.PlayerRealm.MOON and is_instance_valid(_moon):
		return _moon.surface_position(moon_direction_at(chart_position)).distance_to(
			MoonWorld.PLAYABLE_CENTER) - MoonWorld.PLAYABLE_RADIUS_METERS
	return Gen.height(chart_position.x, chart_position.y)


func _map_coordinates(world_position: Vector3) -> Vector2:
	return moon_map_coordinates(world_position) if _map_realm == Net.PlayerRealm.MOON \
		else Vector2(world_position.x, world_position.z)


func _meters_per_px(tier: int) -> float:
	return float(MOON_TIER_METERS_PER_PX[tier] if _map_realm == Net.PlayerRealm.MOON \
		else TIER_METERS_PER_PX[tier])


func _cache_moon_landmarks() -> void:
	_moon_landmarks.clear()
	if not is_instance_valid(_moon):
		return
	for definition in [[&"farm", "FARM", Color(0.98, 0.83, 0.30)],
			[&"market", "MUENSTER", Color(1.0, 0.66, 0.24)],
			[&"aging", "CELLAR", Color(0.97, 0.74, 0.51)],
			[&"observatory", "OBSERVATORY", Color(0.50, 0.83, 1.0)],
			[&"relay", "O₂ RELAY", Color(0.42, 0.96, 0.80)],
			[&"crystal_garden", "CRYSTALS", Color(0.80, 0.61, 1.0)]]:
		_moon_landmarks.append({"id": str(definition[0]), "name": definition[1],
			"position": _moon.to_global(_moon.surface_position(
				MoonColony.facility_direction(definition[0]))), "color": definition[2]})
	_moon_landmarks.append({"id": "rocket", "name": "LANDING PAD",
		"position": _moon.to_global(_moon.landing_transform().origin),
		"color": Color(0.94, 0.98, 1.0)})


func marker_snapshot() -> Array[Dictionary]:
	var markers: Array[Dictionary] = []
	if not world:
		return markers
	for peer_id in world.puppets:
		var actor: Node3D = world.puppets[peer_id]
		if is_instance_valid(actor) and Net.player_realm(int(peer_id)) == _map_realm:
			markers.append({"id": peer_id, "name": str(Net.names.get(peer_id, "")),
				"position": actor.global_position, "color": Color(0.35, 0.75, 1.0),
				"kind": "player"})
	if _map_realm == Net.PlayerRealm.EARTH and is_instance_valid(world.ai_opponent):
		markers.append({"id": -1, "name": "Captain Peel", "kind": "player",
			"position": world.ai_opponent.global_position, "color": Color(1.0, 0.42, 0.30)})
	if _map_realm == Net.PlayerRealm.MOON:
		for landmark in _moon_landmarks:
			var marker := landmark.duplicate()
			marker.kind = "landmark"
			if str(marker.id) == "rocket" and int(Net.rocket_state.get("phase", -1)) \
					== Net.RocketMissionPhase.MOON_READY:
				marker.name = "ROCKET"
			markers.append(marker)
	return markers


## Only the machine actually driven by this world's local player can rotate the
## map. A remote claim, nearby vehicle, or not-yet-completed seat request must
## never steer another client's presentation.
func locally_driven_vehicle() -> Vehicle:
	var player := _player()
	if player == null:
		return null
	var candidate: Variant = player.get("vehicle")
	if not (candidate is Vehicle) or not is_instance_valid(candidate):
		return null
	var vehicle := candidate as Vehicle
	return vehicle if vehicle.driver == player else null


func _vehicle_flat_heading(vehicle: Vehicle) -> Vector2:
	var basis := vehicle.get_global_transform_interpolated().basis
	return Vector2(basis.z.x, basis.z.z)


## Read-only diagnostic hook: radians applied to north-up map data. A driven
## vehicle is always heading-up; ordinary on-foot play remains exactly north-up.
func map_rotation_radians() -> float:
	if _map_realm == Net.PlayerRealm.MOON:
		return 0.0
	var vehicle := locally_driven_vehicle()
	if vehicle == null:
		_heading_vehicle_id = 0
		_last_vehicle_heading = Vector2.UP
		return 0.0
	var instance_id := int(vehicle.get_instance_id())
	if _heading_vehicle_id != instance_id:
		_heading_vehicle_id = instance_id
		_last_vehicle_heading = Vector2.UP
	var flat_heading := _vehicle_flat_heading(vehicle)
	if flat_heading.length_squared() >= VEHICLE_HEADING_MIN_LENGTH_SQUARED:
		_last_vehicle_heading = flat_heading.normalized()
	return _last_vehicle_heading.angle_to(Vector2.UP)


## Read-only diagnostic hook for the local yellow triangle after map rotation.
func local_arrow_forward() -> Vector2:
	if _map_realm == Net.PlayerRealm.MOON and is_instance_valid(_moon):
		var actor := _player()
		var rig: MonkeyRig = actor.get("rig") if actor else null
		if rig and rig.yaw_node:
			var forward := -rig.yaw_node.global_basis.z.normalized()
			var projected := moon_map_coordinates(actor.global_position + forward) \
				- moon_map_coordinates(actor.global_position)
			if projected.length_squared() > 0.000001:
				return projected.normalized()
		return Vector2.UP
	var rotation := map_rotation_radians()
	if locally_driven_vehicle() != null:
		return _last_vehicle_heading.rotated(rotation).normalized()
	var player := _player()
	var yaw := 0.0
	if player and player.get("rig") and player.rig:
		yaw = player.rig.yaw_angle()
	return Vector2(sin(yaw + PI), cos(yaw + PI)).normalized()


## Axis-aligned world coverage required before rotating a square view. At a
## diagonal heading this reaches sqrt(2) times farther and prevents empty corners.
static func tile_request_half_extent(window: float, rotation: float) -> float:
	var coverage_scale := clampf(absf(cos(rotation)) + absf(sin(rotation)),
		1.0, sqrt(2.0))
	return window * 0.5 * coverage_scale


## Rects are expressed around map centre before the shared canvas rotation.
## Testing their rotated AABB avoids discarding a tile that rotates into a corner.
static func rotated_tile_visible(rect: Rect2, rotation: float, px: float) -> bool:
	var minimum := Vector2(INF, INF)
	var maximum := Vector2(-INF, -INF)
	for corner in [rect.position,
			rect.position + Vector2(rect.size.x, 0.0), rect.end,
			rect.position + Vector2(0.0, rect.size.y)]:
		var rotated_corner: Vector2 = corner.rotated(rotation)
		minimum.x = minf(minimum.x, rotated_corner.x)
		minimum.y = minf(minimum.y, rotated_corner.y)
		maximum.x = maxf(maximum.x, rotated_corner.x)
		maximum.y = maxf(maximum.y, rotated_corner.y)
	var half := px * 0.5
	return maximum.x >= -half and minimum.x <= half \
		and maximum.y >= -half and minimum.y <= half


## Exact cache keys whose rotated tile bounds can touch the square viewport.
## Start from the rotated view's conservative AABB, then discard its unused
## corners so a diagonal request does not spend cache or bake work off-screen.
static func required_tile_keys(tier: int, center: Vector2, window: float,
		rotation: float, px: float, meters_per_pixel := -1.0) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	var tile_world := (float(TIER_METERS_PER_PX[tier]) if meters_per_pixel <= 0.0 \
		else meters_per_pixel) * TILE_PX
	var half := tile_request_half_extent(window, rotation)
	var min_tx := floori((center.x - half) / tile_world)
	var max_tx := floori((center.x + half) / tile_world)
	var min_tz := floori((center.y - half) / tile_world)
	var max_tz := floori((center.y + half) / tile_world)
	var scale_px := px / maxf(window, 0.001)
	for tx in range(min_tx, max_tx + 1):
		for tz in range(min_tz, max_tz + 1):
			var key := Vector2i(tx, tz)
			var top_left := (Vector2(key) * tile_world - center) * scale_px
			var rect := Rect2(top_left, Vector2.ONE * tile_world * scale_px)
			if rotated_tile_visible(rect, rotation, px):
				result.append(key)
	return result


## World metres shown across the map: wider the higher the player is.
func window_meters() -> float:
	if _map_realm == Net.PlayerRealm.MOON and is_instance_valid(_moon) and _player():
		var altitude := maxf(_moon.altitude_at(_player().global_position), 0.0)
		return clampf(clampf(240.0 + altitude * 1.5, 240.0, 360.0) \
			* zoom_multiplier, 96.0, 720.0)
	var altitude: float = _player().global_position.y if _player() else 0.0
	return clampf(300.0 + maxf(altitude - 6.0, 0.0) * 40.0, 300.0, 8000.0) \
		* zoom_multiplier


func _pick_tier(needed_m_per_px: float) -> int:
	for tier in range(TIER_METERS_PER_PX.size()):
		if needed_m_per_px <= _meters_per_px(tier) * 2.2:
			return tier
	return TIER_METERS_PER_PX.size() - 1


func _process(_dt: float) -> void:
	_last_baked_rows = 0
	_last_baked_pixels = 0
	_last_preview_samples = 0
	_last_bake_usec = 0
	_last_bake_chunk_usec = 0
	_last_texture_uploads = 0
	if not is_visible_in_tree() or not _player():
		return
	# The HUD is a CanvasLayer, so checking this Control's own visible flag is
	# insufficient. Hidden captures previously kept baking thousands of terrain
	# samples per frame, even with Earth's streaming scheduler stopped.
	var canvas_layer := get_canvas_layer_node()
	if canvas_layer and not canvas_layer.visible:
		return
	# Guard here as well as in HUD: realm packets can precede its next update.
	# A cabin's position does not describe either playable surface map.
	if not _sync_map_context():
		return
	_request_visible_tiles()
	_bake_rows()
	queue_redraw()


func _tile_world(tier: int) -> float:
	return _meters_per_px(tier) * TILE_PX


func _request_visible_tiles() -> void:
	var window := window_meters()
	var center_3d: Vector3 = _player().global_position
	_request_tiles_for_view(_map_coordinates(center_3d), window,
		map_rotation_radians(), map_px())


## The return value and last-request fields are intentionally read-only test
## diagnostics; runtime drawing continues to consume the shared tile cache.
func _request_tiles_for_view(center: Vector2, window: float, rotation: float,
		px: float) -> Dictionary:
	var tier := _pick_tier(window / px)
	var keys := required_tile_keys(tier, center, window, rotation, px, _meters_per_px(tier))
	var required: Dictionary = {}
	for key in keys:
		required[key] = true
		if not _tiles[tier].has(key):
			var image := Image.create(TILE_PX, TILE_PX, false,
				Image.FORMAT_RGBA8)
			# A full-tile representative color is visible immediately. Subsequent
			# row updates refine it, so turning cannot reveal black cache holes.
			image.fill(_placeholder_color(tier, key))
			_tiles[tier][key] = {
				"image": image,
				"texture": ImageTexture.create_from_image(image),
				"rows": 0,
				"cursor": 0,
				"preview_cursor": 0,
				"prev_heights": PackedFloat32Array(),
				"preview_heights": PackedFloat32Array(),
			}
			_bake_queue.append([tier, key])
	_evict(tier, center, required)
	_prioritize_bake_queue(tier, required, center)
	_last_required_tier = tier
	_last_required_keys = required.duplicate()
	return {"tier": tier, "required": required}


func _placeholder_color(tier: int, key: Vector2i) -> Color:
	var tile_world := _tile_world(tier)
	var x := (float(key.x) + 0.5) * tile_world
	var z := (float(key.y) + 0.5) * tile_world
	if _map_realm == Net.PlayerRealm.MOON:
		return _moon_ground_color(map_height_at(Vector2(x, z)))
	var h := Gen.height(x, z)
	if h < Gen.WATER_Y:
		var depth := clampf((Gen.WATER_Y - h) / 5.0, 0.0, 1.0)
		return Color(0.22, 0.52, 0.66).lerp(
			Color(0.05, 0.22, 0.38), depth)
	var ground := Gen.ground_color(h, x, z)
	return Color(ground.r * 0.82, ground.g * 0.82, ground.b * 0.82)


func _moon_ground_color(height: float) -> Color:
	var relief := clampf(0.90 + height * 0.035, 0.53, 1.12)
	return Color(0.59, 0.60, 0.65) * relief


func _evict(tier: int, center: Vector2, protected: Dictionary) -> void:
	var cache: Dictionary = _tiles[tier]
	# The defensive maximum makes visible coverage authoritative even if future
	# zoom rules exceed today's proven bound.
	var limit := maxi(TILES_PER_TIER, protected.size())
	if cache.size() <= limit:
		return
	var tile_world := _tile_world(tier)
	var keys: Array = []
	for key in cache:
		if not protected.has(key):
			keys.append(key)
	keys.sort_custom(func(a, b):
		var pa := (Vector2(a) + Vector2(0.5, 0.5)) * tile_world
		var pb := (Vector2(b) + Vector2(0.5, 0.5)) * tile_world
		return pa.distance_squared_to(center) > pb.distance_squared_to(center))
	var removed: Dictionary = {}
	while cache.size() > limit and not keys.is_empty():
		var gone: Vector2i = keys.pop_front()
		cache.erase(gone)
		removed[gone] = true
	if not removed.is_empty():
		_bake_queue = _bake_queue.filter(
			func(entry): return entry[0] != tier or not removed.has(entry[1]))


func _prioritize_bake_queue(tier: int, required: Dictionary,
		center: Vector2) -> void:
	var current: Array = []
	var rest: Array = []
	for entry in _bake_queue:
		if entry[0] == tier and required.has(entry[1]):
			current.append(entry)
		else:
			rest.append(entry)
	var tile_world := _tile_world(tier)
	current.sort_custom(func(a, b):
		var pa := (Vector2(a[1]) + Vector2(0.5, 0.5)) * tile_world
		var pb := (Vector2(b[1]) + Vector2(0.5, 0.5)) * tile_world
		return pa.distance_squared_to(center) < pb.distance_squared_to(center))
	current.append_array(rest)
	_bake_queue = current


## Visible coarse previews take priority over exact pixels. Each sample block
## is resumable, so even a cold Earth row cannot monopolize a frame.
func _next_bake_queue_index() -> int:
	for index in range(_bake_queue.size()):
		var entry: Array = _bake_queue[index]
		if entry[0] != _last_required_tier or not _last_required_keys.has(entry[1]):
			continue
		var tile: Dictionary = _tiles[entry[0]].get(entry[1], {})
		if not tile.is_empty() and int(tile.get("preview_cursor", 0)) < PREVIEW_SAMPLES:
			return index
	return 0


## A time check every eight samples bounds both terrain types; row ceilings
## remain a secondary work cap. Changed textures upload only once per frame.
func _bake_rows() -> void:
	var started := Time.get_ticks_usec()
	var lunar := _map_realm == Net.PlayerRealm.MOON
	var budget := (MOON_ROWS_PER_FRAME if lunar else ROWS_PER_FRAME) * TILE_PX
	_last_baked_rows = 0
	_last_baked_pixels = 0
	_last_preview_samples = 0
	_last_bake_chunk_usec = 0
	_last_texture_uploads = 0
	var changed: Dictionary = {}
	while budget > 0 and not _bake_queue.is_empty():
		if _last_baked_pixels > 0 \
				and Time.get_ticks_usec() - started >= BAKE_TIME_BUDGET_USEC:
			break
		var queue_index := _next_bake_queue_index()
		var entry: Array = _bake_queue[queue_index]
		var tier: int = entry[0]
		var key: Vector2i = entry[1]
		var tile: Dictionary = _tiles[tier].get(key, {})
		if tile.is_empty():
			_bake_queue.remove_at(queue_index)
			continue
		var rows_done: int = tile.rows
		var count := mini(budget, BAKE_CHUNK_PIXELS)
		var chunk_started := Time.get_ticks_usec()
		if int(tile.get("preview_cursor", 0)) < PREVIEW_SAMPLES:
			count = mini(count, PREVIEW_SAMPLES - int(tile.get("preview_cursor", 0)))
			_bake_preview_pixels(tier, key, tile, count)
			_last_preview_samples += count
		else:
			count = mini(count, TILE_PX * TILE_PX - int(tile.get("cursor", 0)))
			_bake_tile_pixels(tier, key, tile, count)
		_last_bake_chunk_usec = maxi(_last_bake_chunk_usec, Time.get_ticks_usec() - chunk_started)
		budget -= count
		_last_baked_pixels += count
		_last_baked_rows += int(tile.rows) - rows_done
		changed[Vector3i(tier, key.x, key.y)] = tile
		if tile.rows >= TILE_PX:
			_bake_queue.remove_at(queue_index)
	for tile in changed.values():
		(tile.texture as ImageTexture).update(tile.image)
	_last_texture_uploads = changed.size()
	_last_bake_usec = Time.get_ticks_usec() - started


func _sample_color(height: float, x: float, z: float, left_height: float,
		previous_height: float, has_previous_row: bool) -> Color:
	if _map_realm == Net.PlayerRealm.MOON:
		var shade := 0.93 + clampf((left_height - height) * 0.11, -0.23, 0.23)
		if has_previous_row:
			shade += clampf((previous_height - height) * 0.11, -0.23, 0.23)
		return _moon_ground_color(height) * clampf(shade, 0.55, 1.22)
	if height < Gen.WATER_Y:
		var depth := clampf((Gen.WATER_Y - height) / 5.0, 0.0, 1.0)
		return Color(0.22, 0.52, 0.66).lerp(Color(0.05, 0.22, 0.38), depth)
	var color := Gen.ground_color(height, x, z)
	var shade := 0.82 + clampf((left_height - height) * 0.030, -0.16, 0.16)
	if has_previous_row:
		shade += clampf((previous_height - height) * 0.030, -0.16, 0.16)
	return Color(color.r * shade, color.g * shade, color.b * shade)


func _bake_preview_pixels(tier: int, key: Vector2i, tile: Dictionary, count: int) -> void:
	var spacing := _meters_per_px(tier) * PREVIEW_BLOCK_PX
	var origin := Vector2(key) * _tile_world(tier)
	var image: Image = tile.image
	var previous: PackedFloat32Array = tile.preview_heights
	if previous.size() != PREVIEW_GRID_PX:
		previous.resize(PREVIEW_GRID_PX)
	var cursor := int(tile.get("preview_cursor", 0))
	var end := mini(cursor + count, PREVIEW_SAMPLES)
	var left_height := float(tile.get("preview_left_height", 0.0))
	for index in range(cursor, end):
		var row := floori(float(index) / PREVIEW_GRID_PX)
		var column := index % PREVIEW_GRID_PX
		var x := origin.x + (float(column) + 0.5) * spacing
		var z := origin.y + (float(row) + 0.5) * spacing
		if column == 0:
			left_height = map_height_at(Vector2(x - spacing, z))
		var height := map_height_at(Vector2(x, z))
		var color := _sample_color(height, x, z, left_height, previous[column], row > 0)
		image.fill_rect(Rect2i(column * PREVIEW_BLOCK_PX, row * PREVIEW_BLOCK_PX,
			PREVIEW_BLOCK_PX, PREVIEW_BLOCK_PX), color)
		previous[column] = height
		left_height = height
	tile.preview_cursor = end
	tile.preview_heights = previous
	tile.preview_left_height = left_height


## Carry both the west sample and north row through a yield. Interrupted and
## uninterrupted refinement therefore produce identical final terrain pixels.
func _bake_tile_pixels(tier: int, key: Vector2i, tile: Dictionary, count: int) -> void:
	var m_per_px := _meters_per_px(tier)
	var origin_x := float(key.x) * _tile_world(tier)
	var origin_z := float(key.y) * _tile_world(tier)
	var image: Image = tile.image
	var prev: PackedFloat32Array = tile.prev_heights
	if prev.size() != TILE_PX:
		prev.resize(TILE_PX)
	var cursor := int(tile.get("cursor", 0))
	var end := mini(cursor + count, TILE_PX * TILE_PX)
	var left_h := float(tile.get("left_height", 0.0))
	for index in range(cursor, end):
		var row := floori(float(index) / TILE_PX)
		var px := index % TILE_PX
		var z := origin_z + (float(row) + 0.5) * m_per_px
		var x := origin_x + (float(px) + 0.5) * m_per_px
		if px == 0:
			left_h = map_height_at(Vector2(origin_x - m_per_px * 0.5, z))
		var h := map_height_at(Vector2(x, z))
		image.set_pixel(px, row, _sample_color(h, x, z, left_h, prev[px], row > 0))
		left_h = h
		prev[px] = h
	tile.cursor = end
	tile.rows = floori(float(end) / TILE_PX)
	tile.prev_heights = prev
	tile.left_height = left_h


func _world_to_map(world_pos: Vector3, center: Vector3,
		window: float, rotation := NAN) -> Vector2:
	var scale_px := map_px() / window
	var active_rotation: float = map_rotation_radians() \
		if is_nan(rotation) else float(rotation)
	var offset := (_map_coordinates(world_pos) - _map_coordinates(center)) * scale_px
	return Vector2.ONE * map_px() * 0.5 + offset.rotated(active_rotation)


func _draw() -> void:
	if not _player() or Net.player_realm() != _map_realm:
		return
	var px := map_px()
	var window := window_meters()
	var tier := _pick_tier(window / px)
	var center: Vector3 = _player().global_position
	var chart_center := _map_coordinates(center)
	var map_rotation := map_rotation_radians()
	_drawn_label_rects.clear()
	_drawn_label_rects.append(Rect2(Vector2.ONE * (px * 0.5 - 9.0), Vector2.ONE * 18.0))
	draw_rect(Rect2(0, 0, px, px), Color(0.05, 0.10, 0.14))
	var tile_world := _tile_world(tier)
	var scale_px := px / window
	var cache: Dictionary = _tiles[tier]
	var map_center := Vector2.ONE * px * 0.5
	# One shared transform rotates the already-baked north-up tile cache. Text and
	# markers are drawn after resetting it, so names never turn with the terrain.
	draw_set_transform(map_center, map_rotation, Vector2.ONE)
	for key in cache:
		var tile: Dictionary = cache[key]
		var top_left := Vector2(
			(float(key.x) * tile_world - chart_center.x) * scale_px,
			(float(key.y) * tile_world - chart_center.y) * scale_px)
		var rect := Rect2(top_left, Vector2.ONE * tile_world * scale_px)
		if not rotated_tile_visible(rect, map_rotation, px):
			continue
		draw_texture_rect(tile.texture, rect, false)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

	# Realm filtering prevents a Moon astronaut appearing as an Earth marker.
	for marker in marker_snapshot():
		var marker_name := str(marker.name)
		if _map_realm == Net.PlayerRealm.MOON and str(marker.kind) == "landmark":
			var direction := (_moon.to_local(marker.position) - MoonWorld.PLAYABLE_CENTER).normalized()
			var player_direction := (_moon.to_local(center) - MoonWorld.PLAYABLE_CENTER).normalized()
			var distance := direction.angle_to(player_direction) * MoonWorld.PLAYABLE_RADIUS_METERS
			if distance > window * 0.72:
				# One colony bearing stays useful on the far side, instead of six
				# overlapping destination names piled on the same map edge.
				if str(marker.id) != "rocket":
					continue
				marker_name = "CO-OP %dm" % roundi(distance)
		_draw_marker(marker.position, center, window, marker.color, marker_name, map_rotation)
	var arrow_center := Vector2(px * 0.5, px * 0.5)
	var forward := local_arrow_forward()
	var points := PackedVector2Array([
		arrow_center + forward * 7.0,
		arrow_center - forward * 4.0 + forward.orthogonal() * 4.5,
		arrow_center - forward * 4.0 - forward.orthogonal() * 4.5,
	])
	draw_colored_polygon(points, Color(1.0, 0.95, 0.6))
	draw_polyline(points + PackedVector2Array([points[0]]),
		Color(0.1, 0.1, 0.05), 1.0)

	# Mask any rotated terrain below the square before drawing the upright footer.
	draw_rect(Rect2(0, px, px, 16.0), Color(0.05, 0.10, 0.14))
	# frame + footer: coordinates and window width
	draw_rect(Rect2(0, 0, px, px), Color(0.9, 0.78, 0.35, 0.9), false, 2.0)
	var footer := "%d, %d  ·  %s across" % [int(center.x), int(center.z),
		("%.1f km" % (window / 1000.0)) if window >= 1000.0
			else "%d m" % int(window)]
	if _map_realm == Net.PlayerRealm.MOON:
		footer = "MOON  ·  %d m across" % roundi(window)
		draw_rect(Rect2(5, 5, 43, 16), Color(0.08, 0.10, 0.17, 0.90))
		draw_string(_font, Vector2(9, 17), "MOON", HORIZONTAL_ALIGNMENT_LEFT,
			-1, 10, Color(0.89, 0.91, 1.0))
	draw_string(_font, Vector2(2, px + 12), footer,
		HORIZONTAL_ALIGNMENT_LEFT, px, 10, Color(0.85, 0.92, 0.8))


func _draw_marker(world_pos: Vector3, center: Vector3, window: float,
		color: Color, marker_name: String, rotation := NAN) -> void:
	var pos := _world_to_map(world_pos, center, window, rotation)
	var px := map_px()
	pos = pos.clamp(Vector2(5, 5), Vector2(px - 5, px - 5))
	draw_circle(pos, 4.0, Color(0, 0, 0, 0.8))
	draw_circle(pos, 3.0, color)
	if not marker_name.is_empty():
		var text_pos := pos + Vector2(-marker_name.length() * 2.5, -6.0)
		if _map_realm == Net.PlayerRealm.MOON:
			var text_size := _font.get_string_size(marker_name, HORIZONTAL_ALIGNMENT_LEFT, -1, 10)
			text_pos.x = clampf(pos.x - text_size.x * 0.5, 3.0, maxf(3.0, px - text_size.x - 3.0))
			text_pos.y = clampf(text_pos.y, 29.0, px - 5.0)
			var bounds := Rect2(text_pos - Vector2(1, text_size.y - 3), text_size + Vector2(2, 2))
			for used in _drawn_label_rects:
				if used.intersects(bounds):
					return
			_drawn_label_rects.append(bounds)
		draw_string(_font, text_pos + Vector2(1, 1), marker_name,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(0, 0, 0, 0.85))
		draw_string(_font, text_pos, marker_name,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(1, 1, 1, 0.95))
