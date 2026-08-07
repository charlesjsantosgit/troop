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
const TILES_PER_TIER := 40
const SIZE_SMALL := 180.0
const SIZE_LARGE := 300.0

var world: Node3D
var mode := 0            # 0 small · 1 large · 2 hidden
var zoom_multiplier := 1.0
var _tiles: Array = [{}, {}, {}]   # per tier: Vector2i -> tile dict
var _bake_queue: Array = []        # [tier, key] pairs awaiting rows
var _baked_seed := -1
var _font: Font


func configure(owner_world: Node3D) -> void:
	world = owner_world


func _ready() -> void:
	_font = ThemeDB.fallback_font
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


## World metres shown across the map: wider the higher the player is.
func window_meters() -> float:
	var altitude: float = _player().global_position.y if _player() else 0.0
	return clampf(300.0 + maxf(altitude - 6.0, 0.0) * 40.0, 300.0, 8000.0) \
		* zoom_multiplier


func _pick_tier(needed_m_per_px: float) -> int:
	for tier in range(TIER_METERS_PER_PX.size()):
		if needed_m_per_px <= float(TIER_METERS_PER_PX[tier]) * 2.2:
			return tier
	return TIER_METERS_PER_PX.size() - 1


func _process(_dt: float) -> void:
	if not visible or not _player():
		return
	if Gen.world_seed != _baked_seed:
		_baked_seed = Gen.world_seed
		_tiles = [{}, {}, {}]
		_bake_queue.clear()
	_request_visible_tiles()
	_bake_rows()
	queue_redraw()


func _tile_world(tier: int) -> float:
	return float(TIER_METERS_PER_PX[tier]) * TILE_PX


func _request_visible_tiles() -> void:
	var window := window_meters()
	var tier := _pick_tier(window / map_px())
	var center: Vector3 = _player().global_position
	var tile_world := _tile_world(tier)
	var half := window * 0.5
	var min_tx := floori((center.x - half) / tile_world)
	var max_tx := floori((center.x + half) / tile_world)
	var min_tz := floori((center.z - half) / tile_world)
	var max_tz := floori((center.z + half) / tile_world)
	for tx in range(min_tx, max_tx + 1):
		for tz in range(min_tz, max_tz + 1):
			var key := Vector2i(tx, tz)
			if not _tiles[tier].has(key):
				var image := Image.create(TILE_PX, TILE_PX, false,
					Image.FORMAT_RGB8)
				_tiles[tier][key] = {
					"image": image,
					"texture": ImageTexture.create_from_image(image),
					"rows": 0,
					"prev_heights": PackedFloat32Array(),
				}
				_bake_queue.append([tier, key])
	_evict(tier, Vector2(center.x, center.z))


func _evict(tier: int, center: Vector2) -> void:
	var cache: Dictionary = _tiles[tier]
	if cache.size() <= TILES_PER_TIER:
		return
	var tile_world := _tile_world(tier)
	var keys: Array = cache.keys()
	keys.sort_custom(func(a, b):
		var pa := (Vector2(a) + Vector2(0.5, 0.5)) * tile_world
		var pb := (Vector2(b) + Vector2(0.5, 0.5)) * tile_world
		return pa.distance_squared_to(center) > pb.distance_squared_to(center))
	while cache.size() > TILES_PER_TIER:
		var gone: Vector2i = keys.pop_front()
		cache.erase(gone)
		_bake_queue = _bake_queue.filter(
			func(entry): return entry[0] != tier or entry[1] != gone)


## Bake a bounded number of pixel rows per frame across the pending tiles.
func _bake_rows() -> void:
	var budget := ROWS_PER_FRAME
	while budget > 0 and not _bake_queue.is_empty():
		var entry: Array = _bake_queue[0]
		var tier: int = entry[0]
		var key: Vector2i = entry[1]
		var tile: Dictionary = _tiles[tier].get(key, {})
		if tile.is_empty():
			_bake_queue.pop_front()
			continue
		var rows_done: int = tile.rows
		var rows_now := mini(budget, TILE_PX - rows_done)
		_bake_tile_rows(tier, key, tile, rows_done, rows_now)
		tile.rows = rows_done + rows_now
		budget -= rows_now
		if tile.rows >= TILE_PX:
			(tile.texture as ImageTexture).update(tile.image)
			_bake_queue.pop_front()
		else:
			(tile.texture as ImageTexture).update(tile.image)


func _bake_tile_rows(tier: int, key: Vector2i, tile: Dictionary,
		start_row: int, count: int) -> void:
	var m_per_px := float(TIER_METERS_PER_PX[tier])
	var origin_x := float(key.x) * _tile_world(tier)
	var origin_z := float(key.y) * _tile_world(tier)
	var image: Image = tile.image
	var prev: PackedFloat32Array = tile.prev_heights
	if prev.size() != TILE_PX:
		prev.resize(TILE_PX)
	for row in range(start_row, start_row + count):
		var z := origin_z + (float(row) + 0.5) * m_per_px
		var left_h := Gen.height(origin_x - m_per_px * 0.5, z)
		for px in range(TILE_PX):
			var x := origin_x + (float(px) + 0.5) * m_per_px
			var h := Gen.height(x, z)
			var color: Color
			if h < Gen.WATER_Y:
				var depth: float = clampf((Gen.WATER_Y - h) / 5.0, 0.0, 1.0)
				color = Color(0.22, 0.52, 0.66).lerp(
					Color(0.05, 0.22, 0.38), depth)
			else:
				color = Gen.ground_color(h, x, z)
				# Hillshade from the west and north neighbours already sampled
				# this pass — sun-from-northwest relief like map tiles.
				var shade := 0.82
				shade += clampf((left_h - h) * 0.030, -0.16, 0.16)
				if start_row + row > 0 or prev[px] != 0.0:
					shade += clampf((prev[px] - h) * 0.030, -0.16, 0.16)
				color = Color(color.r * shade, color.g * shade,
					color.b * shade)
			image.set_pixel(px, row, color)
			left_h = h
			prev[px] = h
	tile.prev_heights = prev


func _world_to_map(world_pos: Vector3, center: Vector3,
		window: float) -> Vector2:
	var scale_px := map_px() / window
	return Vector2(map_px() * 0.5 + (world_pos.x - center.x) * scale_px,
		map_px() * 0.5 + (world_pos.z - center.z) * scale_px)


func _draw() -> void:
	if not _player():
		return
	var px := map_px()
	var window := window_meters()
	var tier := _pick_tier(window / px)
	var center: Vector3 = _player().global_position
	draw_rect(Rect2(0, 0, px, px), Color(0.05, 0.10, 0.14))
	var tile_world := _tile_world(tier)
	var scale_px := px / window
	var cache: Dictionary = _tiles[tier]
	for key in cache:
		var tile: Dictionary = cache[key]
		var top_left := Vector2(
			px * 0.5 + (float(key.x) * tile_world - center.x) * scale_px,
			px * 0.5 + (float(key.y) * tile_world - center.z) * scale_px)
		var rect := Rect2(top_left, Vector2.ONE * tile_world * scale_px)
		if rect.position.x > px or rect.position.y > px \
				or rect.end.x < 0.0 or rect.end.y < 0.0:
			continue
		draw_texture_rect(tile.texture, rect, false)

	# markers: remote players + AI, then the local arrow on top
	if world:
		for peer_id in world.puppets:
			var puppet: Node3D = world.puppets[peer_id]
			if is_instance_valid(puppet):
				_draw_marker(puppet.global_position, center, window,
					Color(0.35, 0.75, 1.0),
					str(Net.names.get(peer_id, "")))
		if world.ai_opponent and is_instance_valid(world.ai_opponent):
			_draw_marker(world.ai_opponent.global_position, center, window,
				Color(1.0, 0.42, 0.30), "Captain Peel")
	var yaw: float = 0.0
	var player := _player()
	if player.get("rig") and player.rig:
		yaw = player.rig.yaw_angle()
	var arrow_center := Vector2(px * 0.5, px * 0.5)
	var forward := Vector2(sin(yaw + PI), cos(yaw + PI))
	var points := PackedVector2Array([
		arrow_center + forward * 7.0,
		arrow_center - forward * 4.0 + forward.orthogonal() * 4.5,
		arrow_center - forward * 4.0 - forward.orthogonal() * 4.5,
	])
	draw_colored_polygon(points, Color(1.0, 0.95, 0.6))
	draw_polyline(points + PackedVector2Array([points[0]]),
		Color(0.1, 0.1, 0.05), 1.0)

	# frame + footer: coordinates and window width
	draw_rect(Rect2(0, 0, px, px), Color(0.9, 0.78, 0.35, 0.9), false, 2.0)
	var footer := "%d, %d  ·  %s across" % [int(center.x), int(center.z),
		("%.1f km" % (window / 1000.0)) if window >= 1000.0
			else "%d m" % int(window)]
	draw_string(_font, Vector2(2, px + 12), footer,
		HORIZONTAL_ALIGNMENT_LEFT, px, 10, Color(0.85, 0.92, 0.8))


func _draw_marker(world_pos: Vector3, center: Vector3, window: float,
		color: Color, marker_name: String) -> void:
	var pos := _world_to_map(world_pos, center, window)
	var px := map_px()
	pos = pos.clamp(Vector2(5, 5), Vector2(px - 5, px - 5))
	draw_circle(pos, 4.0, Color(0, 0, 0, 0.8))
	draw_circle(pos, 3.0, color)
	if not marker_name.is_empty():
		var text_pos := pos + Vector2(-marker_name.length() * 2.5, -6.0)
		draw_string(_font, text_pos + Vector2(1, 1), marker_name,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(0, 0, 0, 0.85))
		draw_string(_font, text_pos, marker_name,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(1, 1, 1, 0.95))
