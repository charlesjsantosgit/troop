class_name WorldMap
extends Control
## Seeded cartographic atlas of the playable terrain. A private worker samples
## the same Earth generator and lunar collision triangles; canvas vectors retain
## sharp roads, footprints and labels at every zoom. No photographic atlas is
## used as navigation data.
const Cartography = preload("res://scripts/cartography_source.gd")
const Plan = preload("res://scripts/city_plan.gd")
const Towns = preload("res://scripts/frontier_town_layout.gd")
const Highways = preload("res://scripts/highway_plan.gd")
const MenuTheme = preload("res://scripts/menu_theme.gd")

signal opened
signal closed
signal body_selected(body: int)

enum CelestialBody { EARTH, MOON }

const EARTH_CIRCUMFERENCE_FALLBACK := 40_075_016.686
const MOON_CIRCUMFERENCE_M := 10_921_000.0
const TILE_PX := 128
const TILE_METERS_PER_PX := [0.5, 1.0, 2.0, 4.0, 8.0, 16.0, 32.0, 64.0, 128.0, 256.0, 512.0, 1024.0, 2048.0, 4096.0, 8192.0, 16384.0]
const CACHE_TILE_LIMIT := 64
const LOCAL_BAKE_SAMPLES_PER_FRAME := 64
const LOCAL_SAMPLES_PER_TILE_TURN := 12
# The canvas thread does no terrain sampling; worker publication is bounded.
const GLOBE_BAKE_SAMPLES_PER_FRAME := 64
const BAKE_TIME_BUDGET_USEC := 1800
# Each tile reaches one shared-generator sample per texture pixel.
const LOCAL_PREVIEW_GRIDS := [4, 8, 16, 32, 64, 128]
const GLOBE_ATLAS_SIZE := Vector2i(1025, 513)
const MOON_ATLAS_SIZE := Vector2i(1025, 513)
const GLOBE_LONGITUDE_STEPS := 96
const GLOBE_LATITUDE_STEPS := 48
static var EARTH_ATLAS: Texture2D:
	get:
		return SharedTextureCache.get_texture(SharedTextureCache.EARTH_PATH)
static var MOON_ATLAS: Texture2D:
	get:
		return SharedTextureCache.get_texture(SharedTextureCache.MOON_PATH)
static var SATELLITE_DETAIL_OVERLAY: Texture2D:
	get:
		return SharedTextureCache.get_texture(SharedTextureCache.MICRODETAIL_PATH)
const MOON_LIGHT_SCREEN := Vector3(-0.42, -0.30, 0.855)
const MIN_VIEW_SPAN_M := 120.0
const GLOBE_BLEND_START_FRACTION := 0.20
const GLOBE_FULL_FRACTION := 0.42
const MAX_VIEW_SPAN_FRACTION := 1.08
const HEADER_H := 72.0
const FOOTER_H := 68.0
const MAP_MARGIN := 24.0
const ZOOM_RESPONSE := 12.0
const PAN_RESPONSE := 14.0
const HOVER_SAMPLE_SECONDS := 0.12
const PLAYER_MARKER_WORLD_LENGTH := 90.0

var _worker := Thread.new()
var _cartography := Cartography.new()
var _worker_job: Dictionary = {}
var _context_signature := ""
var _moon_probe: MoonWorld
var _atlas_levels := [0, 0]
var _atlas_stages := [32, 64, 128, 256, 512, 1024]
var _body_views: Dictionary = {}
var _last_worker_samples := 0
var _source_cache_stats: Dictionary = {}
var _last_publish_usec := 0
var _last_update_usec := 0
var _last_draw_usec := 0
var _landmark_cache: Array[Dictionary] = []
var _landmark_timer := 0.0
var _outline_blocks: Dictionary = {}
var _source_roads: Array = []
var _footprint_view_bounds := Rect2(Vector2.INF, Vector2.ZERO)
var _footprint_view: Array[Dictionary] = []
var _label_rects: Array[Rect2] = []
var world: Node3D
var selected_body := CelestialBody.EARTH
var _open := false
var _mouse_was_captured := true
var _font: Font
var _center := Vector2.ZERO
var _target_center := Vector2.ZERO
var _view_span_m := 8000.0
var _target_span_m := 8000.0
var _dragging := false
var _drag_start := Vector2.ZERO
var _drag_center_start := Vector2.ZERO
var _hover_screen := Vector2(-1000.0, -1000.0)
var _hover_world := Vector2.ZERO
var _hover_sample: Dictionary = {}
var _hover_sample_remaining := 0.0
var _earth_button_rect := Rect2()
var _moon_button_rect := Rect2()
var _close_button_rect := Rect2()
var _home_button_rect := Rect2()
var _moon_globe_rect := Rect2()

# One global LRU, rather than a limit per zoom tier, keeps repeated zooming from
# retaining a texture pyramid. A tile is {image, texture, rows, previous, touch}.
var _tiles: Dictionary = {}
var _bake_queue: Array[String] = []
var _required_keys: Dictionary = {}
var _touch_serial := 0
var _last_baked_samples := 0
var _last_local_texture_uploads := 0
var _baked_seed := -1
var _active_tier := 0

# Each body has its own progressively refined seeded surface atlas.
var _globe_texture: Texture2D
var _globe_stage := 0
var _globe_sample_cursor := 0
var _last_globe_baked_samples := 0
var _earth_sphere_mesh: ArrayMesh
var _earth_mesh_view := Vector2(INF, INF)
var _moon_texture: Texture2D
var _moon_sphere_mesh: ArrayMesh
var _moon_mesh_view := Vector2(INF, INF)


func configure(owner_world: Node3D) -> void:
	world = owner_world


func _ready() -> void:
	_font = ThemeDB.fallback_font
	set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	clip_contents = true
	get_viewport().size_changed.connect(_resize_panel)
	_resize_panel()
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_ALL
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	visible = false
	set_process(false)
	set_process_input(false)


func _resize_panel() -> void:
	var viewport := get_viewport_rect().size
	size = Vector2(minf(1380.0, viewport.x * .94), minf(920.0, viewport.y * .9))
	position = (viewport - size) * .5
	queue_redraw()


func is_open() -> bool:
	return _open


func open_map() -> void:
	if _open:
		return
	_open = true
	visible = true
	set_process(true)
	set_process_input(true)
	_mouse_was_captured = Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_sync_seed()
	if world and world.get("local_player"):
		recenter_on_player()
		_center = _target_center
	_target_span_m = clampf(_target_span_m, MIN_VIEW_SPAN_M,
		body_circumference() * MAX_VIEW_SPAN_FRACTION)
	_view_span_m = _target_span_m
	grab_focus()
	queue_redraw()
	opened.emit()


func close_map() -> void:
	if not _open:
		return
	_open = false
	_cartography.cancelled = true
	_dragging = false
	visible = false
	set_process(false)
	set_process_input(false)
	if _mouse_was_captured and DisplayServer.get_name() != "headless":
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	closed.emit()


func toggle() -> void:
	if _open:
		close_map()
	else:
		open_map()


func focus_earth() -> void:
	_select_body(CelestialBody.EARTH)


func focus_moon() -> void:
	_select_body(CelestialBody.MOON)


func recenter_on_player() -> void:
	if not world or not world.get("local_player"): return
	var realm := Net.player_realm()
	_select_body(CelestialBody.MOON if realm == Net.PlayerRealm.MOON else CelestialBody.EARTH)
	var p: Node3D = world.get("local_player")
	_target_center = nearest_equivalent_xz(coordinates_for_position(p.global_position, selected_body),
		_center, body_circumference())


func _process(dt: float) -> void:
	if not _open: return
	var update_started := Time.get_ticks_usec()
	_sync_seed()
	_target_span_m = clampf(_target_span_m, MIN_VIEW_SPAN_M, body_circumference() * MAX_VIEW_SPAN_FRACTION)
	_center = _center.lerp(_target_center, 1.0 - exp(-PAN_RESPONSE * dt))
	_view_span_m = exp(lerpf(log(maxf(_view_span_m, 1.0)), log(maxf(_target_span_m, 1.0)), 1.0 - exp(-ZOOM_RESPONSE * dt)))
	_keyboard_pan(dt)
	_last_baked_samples = 0
	_last_globe_baked_samples = 0
	_last_local_texture_uploads = 0
	if globe_blend() < .995: _request_visible_tiles()
	_pump_worker()
	_landmark_timer -= dt
	if _landmark_timer <= 0.0:
		_landmark_cache = landmark_snapshot()
		_landmark_timer = .5
	_update_hover(dt)
	queue_redraw()
	_last_update_usec = Time.get_ticks_usec() - update_started


func _keyboard_pan(dt: float) -> void:
	if _dragging:
		return
	var direction := Vector2.ZERO
	if Input.is_physical_key_pressed(KEY_LEFT) or Input.is_physical_key_pressed(KEY_A):
		direction.x -= 1.0
	if Input.is_physical_key_pressed(KEY_RIGHT) or Input.is_physical_key_pressed(KEY_D):
		direction.x += 1.0
	if Input.is_physical_key_pressed(KEY_UP) or Input.is_physical_key_pressed(KEY_W):
		direction.y -= 1.0
	if Input.is_physical_key_pressed(KEY_DOWN) or Input.is_physical_key_pressed(KEY_S):
		direction.y += 1.0
	if direction.length_squared() > 0.0:
		_target_center += direction.normalized() * _target_span_m * dt * 0.52


func _gui_input(event: InputEvent) -> void:
	if not _open:
		return
	if event is InputEventMouseMotion:
		var motion := event as InputEventMouseMotion
		_hover_screen = motion.position
		if _dragging:
			var delta: Vector2 = motion.position - _drag_start
			var rect := map_rect()
			var scale := _target_span_m / maxf(rect.size.x, 1.0)
			_target_center = _drag_center_start - delta * scale
			_hover_sample_remaining = 0.0
		accept_event()
	elif event is InputEventMouseButton:
		if event.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_MIDDLE]:
			if event.pressed:
				if _handle_click(event.position):
					accept_event()
					return
				if map_rect().has_point(event.position):
					_dragging = true
					_drag_start = event.position
					_drag_center_start = _target_center
					accept_event()
			else:
				_dragging = false
				accept_event()
		elif event.pressed and event.button_index in [MOUSE_BUTTON_WHEEL_UP,
				MOUSE_BUTTON_WHEEL_DOWN]:
			var factor := 0.72 if event.button_index == MOUSE_BUTTON_WHEEL_UP \
				else 1.38
			zoom_at(event.position, factor)
			accept_event()


func _handle_click(point: Vector2) -> bool:
	if _close_button_rect.has_point(point):
		close_map()
		return true
	if _home_button_rect.has_point(point):
		recenter_on_player()
		return true
	if _earth_button_rect.has_point(point):
		focus_earth()
		return true
	if _moon_button_rect.has_point(point) or _moon_globe_rect.has_point(point):
		focus_moon()
		return true
	return false


func zoom_at(screen_point: Vector2, factor: float) -> void:
	var rect := map_rect()
	var old_span := _target_span_m
	var new_span := clampf(old_span * factor, MIN_VIEW_SPAN_M, body_circumference() * MAX_VIEW_SPAN_FRACTION)
	if rect.has_point(screen_point):
		_target_center = zoom_anchored_center(_target_center, screen_point, rect, old_span, new_span)
	_target_span_m = new_span


func map_rect() -> Rect2:
	return Rect2(MAP_MARGIN, HEADER_H,
		maxf(size.x - MAP_MARGIN * 2.0, 1.0),
		maxf(size.y - HEADER_H - FOOTER_H, 1.0))


func globe_blend() -> float:
	var circumference := body_circumference()
	var start := .34 if selected_body == CelestialBody.MOON else GLOBE_BLEND_START_FRACTION
	var full := .58 if selected_body == CelestialBody.MOON else GLOBE_FULL_FRACTION
	return smoothstep(circumference * start, circumference * full, _view_span_m)


## Alpha pair for the planar-to-orbital transition: x is local terrain and y
## is the globe. Keeping the sum at one prevents a brightness pulse mid-zoom.
static func transition_opacities(blend: float) -> Vector2:
	var globe_alpha := smoothstep(0.0, 1.0, clampf(blend, 0.0, 1.0))
	return Vector2(1.0 - globe_alpha, globe_alpha)


static func transition_globe_scale(blend: float) -> float:
	# The globe first appears larger than the viewport, like a camera lifting off
	# the surface, then settles into the complete planetary view.
	return lerpf(2.15, 1.0, smoothstep(0.0, 1.0,
		clampf(blend, 0.0, 1.0)))


static func shared_earth_texture() -> Texture2D:
	return EARTH_ATLAS


static func shared_moon_texture() -> Texture2D:
	return MOON_ATLAS


static func _with_alpha(color: Color, alpha: float) -> Color:
	color.a *= clampf(alpha, 0.0, 1.0)
	return color


static func planet_circumference_m() -> float:
	return Gen.PLANET_CIRCUMFERENCE


## Canonical equirectangular coordinates for a sphere. Longitude wraps. Passing
## a pole reflects latitude and advances longitude by 180 degrees; this is the
## key distinction from toroidal X/Z wrapping.
static func canonical_planet_xz(point: Vector2,
		circumference := EARTH_CIRCUMFERENCE_FALLBACK) -> Vector2:
	var c := maxf(float(circumference), 1.0)
	var x := point.x
	var z := wrapf(point.y, -c * 0.5, c * 0.5)
	if z > c * 0.25:
		z = c * 0.5 - z
		x += c * 0.5
	elif z < -c * 0.25:
		z = -c * 0.5 - z
		x += c * 0.5
	x = wrapf(x, -c * 0.5, c * 0.5)
	return Vector2(x, z)


static func world_xz_to_lon_lat(point: Vector2,
		circumference := EARTH_CIRCUMFERENCE_FALLBACK) -> Vector2:
	var c := maxf(float(circumference), 1.0)
	var canonical := canonical_planet_xz(point, c)
	return Vector2(canonical.x * TAU / c, canonical.y * TAU / c)


static func lon_lat_to_world_xz(lon_lat: Vector2,
		circumference := EARTH_CIRCUMFERENCE_FALLBACK) -> Vector2:
	var c := maxf(float(circumference), 1.0)
	return canonical_planet_xz(Vector2(lon_lat.x * c / TAU,
		lon_lat.y * c / TAU), c)


## Find the same spherical point in the closest unfolded map copy. Candidates
## include ordinary date-line wraps and both pole-reflected representations.
static func nearest_equivalent_xz(point: Vector2, reference: Vector2,
		circumference := EARTH_CIRCUMFERENCE_FALLBACK) -> Vector2:
	var c := maxf(float(circumference), 1.0)
	var p := canonical_planet_xz(point, c)
	var best := p
	var best_distance := INF
	for origin in [p, Vector2(p.x + c * .5, c * .5 - p.y)]:
		var cycle := Vector2i(roundi((reference.x - origin.x) / c), roundi((reference.y - origin.y) / c))
		for dx in range(cycle.x - 1, cycle.x + 2):
			for dz in range(cycle.y - 1, cycle.y + 2):
				var candidate: Vector2 = origin + Vector2(dx, dz) * c
				var distance := candidate.distance_squared_to(reference)
				if distance < best_distance:
					best = candidate
					best_distance = distance
	return best


static func zoom_anchored_center(center: Vector2, cursor: Vector2, rect: Rect2,
		old_span: float, new_span: float) -> Vector2:
	var normalized := (cursor - rect.get_center()) / maxf(rect.size.x, 1.0)
	return center + normalized * (old_span - new_span)


static func unit_from_lon_lat(lon_lat: Vector2) -> Vector3:
	var cos_lat := cos(lon_lat.y)
	return Vector3(sin(lon_lat.x) * cos_lat, sin(lon_lat.y),
		cos(lon_lat.x) * cos_lat)


static func globe_projection(lon_lat: Vector2, view_lon_lat: Vector2,
		center: Vector2, radius: float) -> Dictionary:
	var forward := unit_from_lon_lat(view_lon_lat).normalized()
	var right := Vector3.UP.cross(forward)
	if right.length_squared() < 0.000001:
		right = Vector3.RIGHT
	else:
		right = right.normalized()
	var up := forward.cross(right).normalized()
	var surface := unit_from_lon_lat(lon_lat)
	var depth := surface.dot(forward)
	return {
		"position": center + Vector2(surface.dot(right),
			-surface.dot(up)) * radius,
		"depth": depth,
		"visible": depth >= 0.0,
	}


static func marker_forward(yaw: float) -> Vector2:
	return Vector2(sin(yaw + PI), cos(yaw + PI)).normalized()


static func realm_visible_on_body(realm: int, body: int) -> bool:
	return (body == CelestialBody.EARTH and realm == Net.PlayerRealm.EARTH) \
		or (body == CelestialBody.MOON and realm == Net.PlayerRealm.MOON)


## Local lunar points project from their true radial direction; rotating the
## globe cannot change the location of a landmark.
static func moon_marker_lon_lat(position: Vector3,
		_view_lon_lat := Vector2.ZERO) -> Vector2:
	return Cartography.lunar_coordinate(position - MoonWorld.PLAYABLE_CENTER) / MoonWorld.PLAYABLE_RADIUS_METERS


static func moon_marker_projection(position: Vector3, yaw: float,
		center: Vector2, radius: float,
		view_lon_lat := Vector2.ZERO) -> Dictionary:
	var projected := globe_projection(moon_marker_lon_lat(position, view_lon_lat),
		view_lon_lat, center, radius)
	var facing := marker_forward(yaw)
	var ahead_position := position + Vector3(facing.x, 0.0, facing.y) \
		* PLAYER_MARKER_WORLD_LENGTH
	var ahead := globe_projection(moon_marker_lon_lat(ahead_position,
		view_lon_lat), view_lon_lat, center, radius)
	var projected_position: Vector2 = projected.position
	var ahead_screen_position: Vector2 = ahead.position
	var direction: Vector2 = (ahead_screen_position - projected_position).normalized()
	if direction.length_squared() < 0.1:
		direction = facing
	return {
		"position": projected.position,
		"direction": direction,
		"depth": projected.depth,
		"visible": projected.visible,
	}


static func tier_for_meters_per_pixel(meters_per_pixel: float) -> int:
	for tier in range(TILE_METERS_PER_PX.size()):
		if meters_per_pixel <= float(TILE_METERS_PER_PX[tier]) * 1.65:
			return tier
	return TILE_METERS_PER_PX.size() - 1


static func required_tile_keys(center: Vector2, rect_size: Vector2,
		view_span: float, tier: int) -> Array[Vector2i]:
	var mpp := maxf(view_span / maxf(rect_size.x, 1.0), 0.001)
	var half_world := rect_size * mpp * 0.5
	var tile_world := float(TILE_METERS_PER_PX[tier]) * TILE_PX
	var min_key := Vector2i(floori((center.x - half_world.x) / tile_world),
		floori((center.y - half_world.y) / tile_world))
	var max_key := Vector2i(floori((center.x + half_world.x) / tile_world),
		floori((center.y + half_world.y) / tile_world))
	var keys: Array[Vector2i] = []
	for tx in range(min_key.x, max_key.x + 1):
		for tz in range(min_key.y, max_key.y + 1):
			keys.append(Vector2i(tx, tz))
	return keys


## Pick the first visually sufficient tier, then coarsen only as much as needed
## to honor the global cache cap on 4K/ultrawide displays. This makes display
## resolution affect sharpness, never unbounded memory or bake work.
static func bounded_tier_for_view(center: Vector2, rect_size: Vector2,
		view_span: float, tile_limit := CACHE_TILE_LIMIT) -> int:
	var meters_per_pixel := view_span / maxf(rect_size.x, 1.0)
	var tier := tier_for_meters_per_pixel(meters_per_pixel)
	while tier < TILE_METERS_PER_PX.size() - 1:
		var count := required_tile_keys(center, rect_size, view_span, tier).size()
		if count <= tile_limit:
			break
		tier += 1
	return tier


func marker_snapshot() -> Array[Dictionary]:
	var markers: Array[Dictionary] = []
	if not world:
		return markers
	var local: Variant = world.get("local_player")
	if local is Node3D and is_instance_valid(local):
		var local_node := local as Node3D
		var local_peer_id := int(local_node.get("peer_id"))
		markers.append({
			"id": local_peer_id,
			"name": str(local_node.get("display_name")),
			"position": local_node.global_position,
			"yaw": _actor_yaw(local_node),
			"local": true,
			"realm": Net.player_realm(local_peer_id),
		})
	var puppet_values: Variant = world.get("puppets")
	if puppet_values is Dictionary:
		for peer_value in puppet_values:
			var peer_id := int(peer_value)
			# A puppet can enter the tree before its authoritative world snapshot.
			# Suppress that unclassified interval instead of defaulting it to Earth.
			if not Net.player_realms.has(peer_id):
				continue
			var actor: Variant = puppet_values[peer_value]
			if actor is Node3D and is_instance_valid(actor):
				var node := actor as Node3D
				markers.append({
					"id": peer_id,
					"name": str(Net.names.get(peer_id,
						node.get("display_name"))),
					"position": node.global_position,
					"yaw": _actor_yaw(node),
					"local": false,
					"realm": Net.player_realm(peer_id),
				})
	return markers


func markers_for_body(body: int) -> Array[Dictionary]:
	var visible_markers: Array[Dictionary] = []
	for marker in marker_snapshot():
		if realm_visible_on_body(int(marker.realm), body):
			visible_markers.append(marker)
	return visible_markers


func _actor_yaw(actor: Node3D) -> float:
	var actor_rig: Variant = actor.get("rig")
	if actor_rig and is_instance_valid(actor_rig) \
			and actor_rig.has_method("yaw_angle"):
		return float(actor_rig.call("yaw_angle"))
	var replicated_yaw: Variant = actor.get("_yaw")
	return float(replicated_yaw) if replicated_yaw != null else actor.rotation.y


func _canonical_sample_xz(point: Vector2) -> Vector2:
	if Gen.has_method("canonical_planet_xz"):
		var canonical_planet: Variant = Gen.call("canonical_planet_xz", point)
		if canonical_planet is Vector2:
			return canonical_planet
	if Gen.has_method("canonical_world_xz"):
		var result: Variant = Gen.call("canonical_world_xz", point)
		if result is Vector2:
			return result
	if Gen.has_method("canonical_xz"):
		var alternate: Variant = Gen.call("canonical_xz", point)
		if alternate is Vector2:
			return alternate
	return canonical_planet_xz(point, planet_circumference_m())


func _map_sample(point: Vector2, _meters_per_pixel: float) -> Dictionary:
	if selected_body == CelestialBody.MOON:
		var source := source_moon()
		var elevation := source.surface_position(Cartography.lunar_direction(point)).distance_to(MoonWorld.PLAYABLE_CENTER) - MoonWorld.PLAYABLE_RADIUS_METERS
		return {"elevation": elevation, "water": false, "color": Color("aaa79c"), "biome": -1}
	var canonical := Gen.canonical_planet_xz(point)
	var actual := Gen.terrain_vertex_sample(canonical.x, canonical.y)
	actual.water = float(actual.elevation) < Gen.WATER_Y
	if Gen.frontier_world and Plan.pond_depth(canonical) > Plan.GROUND_Y - Plan.POND_SURFACE_Y:
		actual.water = true
	actual.biome = Gen.biome_at_height(canonical.x, canonical.y, float(actual.elevation))
	return actual


func _sync_seed() -> void:
	var source := source_moon()
	var signature := "%d:%d:%s:%s" % [Gen.world_seed, source.moon_seed, Gen.frontier_world, Gen.debug_world]
	if signature == _context_signature: return
	_context_signature = signature
	_baked_seed = Gen.world_seed
	_tiles.clear()
	_bake_queue.clear()
	_required_keys.clear()
	_outline_blocks.clear()
	_footprint_view_bounds = Rect2(Vector2.INF, Vector2.ZERO)
	_footprint_view.clear()
	_source_roads = Gen.road_routes()
	_atlas_levels = [0, 0]
	_globe_texture = null
	_moon_texture = null
	_landmark_timer = 0.0


func _request_visible_tiles() -> void:
	var rect := map_rect()
	var tier := bounded_tier_for_view(_center, rect.size, _view_span_m)
	_active_tier = tier
	var keys := required_tile_keys(_center, rect.size, _view_span_m, tier)
	_required_keys.clear()
	_touch_serial += 1
	for tile_key in keys:
		var cache_key := _cache_key(tier, tile_key)
		_required_keys[cache_key] = true
		if not _tiles.has(cache_key):
			_create_tile(cache_key, tier, tile_key)
		_tiles[cache_key].touch = _touch_serial
	_prioritize_bakes()
	_evict_tiles()


func _cache_key(tier: int, tile_key: Vector2i) -> String:
	return "%d:%d:%d:%d" % [selected_body, tier, tile_key.x, tile_key.y]


func _create_tile(cache_key: String, tier: int, tile_key: Vector2i) -> void:
	var image := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	image.fill(Color("657781") if selected_body == CelestialBody.MOON else Color("648a85"))
	_tiles[cache_key] = {"body": selected_body, "tier": tier, "key": tile_key,
		"image": image, "texture": ImageTexture.create_from_image(image),
		"stage": 0, "touch": _touch_serial}
	_bake_queue.append(cache_key)


## Finish a shared-edge coarse preview across the viewport before refinement.
func _prioritize_bakes() -> void:
	var current: Array[String] = []
	var rest: Array[String] = []
	for cache_key in _bake_queue:
		if _required_keys.has(cache_key):
			current.append(cache_key)
		else:
			rest.append(cache_key)
	# Refine the centre of the view first. It is the point beneath the cursor
	# during wheel zoom, so the place the player is inspecting reaches its live
	# coastline/road pass before off-screen cache padding.
	current.sort_custom(func(a: String, b: String):
		if not _tiles.has(a) or not _tiles.has(b):
			return a < b
		var a_tile: Dictionary = _tiles[a]
		var b_tile: Dictionary = _tiles[b]
		# Give every visible tile a smooth shared-edge preview before spending
		# samples on a finer centre tile. Distance breaks ties within one stage.
		if int(a_tile.stage) != int(b_tile.stage):
			return int(a_tile.stage) < int(b_tile.stage)
		var a_world := (Vector2(a_tile.key) + Vector2(0.5, 0.5)) \
			* float(TILE_METERS_PER_PX[int(a_tile.tier)]) * TILE_PX
		var b_world := (Vector2(b_tile.key) + Vector2(0.5, 0.5)) \
			* float(TILE_METERS_PER_PX[int(b_tile.tier)]) * TILE_PX
		return a_world.distance_squared_to(_center) \
			< b_world.distance_squared_to(_center))
	current.append_array(rest)
	_bake_queue = current


func _evict_tiles() -> void:
	if _tiles.size() <= maxi(CACHE_TILE_LIMIT, _required_keys.size()):
		return
	var candidates: Array[String] = []
	for cache_key in _tiles:
		if not _required_keys.has(cache_key):
			candidates.append(cache_key)
	candidates.sort_custom(func(a: String, b: String):
		return int(_tiles[a].touch) < int(_tiles[b].touch))
	var limit := maxi(CACHE_TILE_LIMIT, _required_keys.size())
	var removed: Dictionary = {}
	while _tiles.size() > limit and not candidates.is_empty():
		var gone: String = candidates.pop_front()
		_tiles.erase(gone)
		removed[gone] = true
	if not removed.is_empty():
		_bake_queue = _bake_queue.filter(
			func(cache_key): return not removed.has(cache_key))


func _bake_local_samples(_maximum_samples: int) -> void:
	_pump_worker()


## Total actual terrain evaluations through all local refinement stages.
static func local_samples_per_complete_tile() -> int:
	var samples := 0
	for grid in LOCAL_PREVIEW_GRIDS:
		var shared_edge_grid := int(grid) + 1
		samples += shared_edge_grid * shared_edge_grid
	return samples


static func _pixel_hash(x: int, y: int) -> float:
	var value := x * 374761393 + y * 668265263
	value = (value ^ (value >> 13)) * 1274126177
	return float(value & 0xffff) / 65535.0


func _ensure_globe_atlas() -> void:
	pass


func _bake_globe_samples(_maximum_samples: int) -> void:
	_pump_worker()


func _update_hover(dt: float) -> void:
	_hover_sample_remaining -= dt
	if _hover_sample_remaining > 0.0 or not map_rect().has_point(_hover_screen):
		return
	_hover_sample_remaining = HOVER_SAMPLE_SECONDS
	_hover_world = screen_to_world(_hover_screen)
	_hover_sample = _map_sample(_hover_world,
		_view_span_m / maxf(map_rect().size.x, 1.0))


func screen_to_world(screen_point: Vector2) -> Vector2:
	var rect := map_rect()
	var mpp := _view_span_m / maxf(rect.size.x, 1.0)
	return _center + (screen_point - rect.get_center()) * mpp


func world_to_screen(world_point: Vector2) -> Vector2:
	var rect := map_rect()
	var c := body_circumference()
	var delta := (world_point - _center).abs()
	# Most vector vertices are in the current local chart. Avoid a 54-candidate
	# spherical-image search for every corner of every visible city building.
	var equivalent := world_point if maxf(delta.x, delta.y) < c * .25 else nearest_equivalent_xz(world_point, _center, c)
	var mpp := _view_span_m / maxf(rect.size.x, 1.0)
	return rect.get_center() + (equivalent - _center) / maxf(mpp, .001)


func _draw() -> void:
	if not _open: return
	var draw_started := Time.get_ticks_usec()
	_label_rects.clear()
	_draw_backdrop()
	var blend := globe_blend()
	var opacities := transition_opacities(blend)
	if opacities.x > .001: _draw_local_map(opacities.x)
	if opacities.y > .001: _draw_globe_view(opacities.y, transition_globe_scale(blend))
	_draw_chrome(blend)
	_last_draw_usec = Time.get_ticks_usec() - draw_started


func _draw_backdrop() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color("040912"))
	# Stable code-native star field. It costs no nodes, textures, or per-frame RNG.
	for index in range(96):
		var hx := _pixel_hash(index * 17 + 3, 71)
		var hy := _pixel_hash(index * 31 + 9, 193)
		var radius := 0.55 + _pixel_hash(index, 811) * 1.25
		var alpha := 0.28 + _pixel_hash(index, 1217) * 0.62
		draw_circle(Vector2(hx * size.x, hy * size.y), radius,
			Color(0.72, 0.85, 1.0, alpha))


func _draw_local_map(alpha := 1.0) -> void:
	_moon_globe_rect = Rect2()
	var rect := map_rect()
	draw_rect(rect, _with_alpha(Color("0c2632"), alpha))
	var mpp := _view_span_m / maxf(rect.size.x, 1.0)
	var tier := _active_tier
	var tile_world := float(TILE_METERS_PER_PX[tier]) * TILE_PX
	for cache_key in _required_keys:
		if not _tiles.has(cache_key):
			continue
		var tile: Dictionary = _tiles[cache_key]
		if int(tile.tier) != tier:
			continue
		var top_left := rect.get_center() \
			+ (Vector2(tile.key) * tile_world - _center) / mpp
		var tile_rect := Rect2(top_left, Vector2.ONE * tile_world / mpp)
		var clipped := tile_rect.intersection(rect)
		if clipped.has_area():
			var texture_size := Vector2(tile.texture.get_width(), tile.texture.get_height())
			var region := tile_texture_region(clipped, tile_rect, texture_size)
			draw_texture_rect_region(tile.texture, clipped, region, Color(1, 1, 1, alpha))
	_draw_cartographic_features(rect, alpha)
	_draw_lat_lon_grid(rect, alpha)
	_draw_local_markers(rect, alpha)
	# Vignette and crisp inner frame make placeholders/refined tiles read as one
	# atlas while the incremental baker catches up.
	draw_rect(rect, _with_alpha(Color(0.02, 0.08, 0.11, 0.18), alpha),
		false, 3.0)
	draw_rect(rect.grow(-2.0),
		_with_alpha(Color(0.58, 0.94, 0.76, 0.42), alpha), false, 1.0)


static func tile_texture_region(clipped: Rect2, tile: Rect2, texture_size: Vector2) -> Rect2:
	# Image samples include both world-space edges. Map the first/last sample
	# centers to those edges; using the full texture width shifts landmarks and
	# produces visible joins when coarse and final stages have different sizes.
	return Rect2(Vector2.ONE * .5 + (clipped.position - tile.position) / tile.size * (texture_size - Vector2.ONE),
		clipped.size / tile.size * (texture_size - Vector2.ONE))


func _draw_lat_lon_grid(rect: Rect2, alpha := 1.0) -> void:
	var circumference := body_circumference()
	var center_geo := world_xz_to_lon_lat(_center, circumference)
	var degrees_across := rad_to_deg(_view_span_m * TAU / circumference)
	var step_degrees := 0.01
	for candidate in [0.01, 0.05, 0.1, 0.5, 1.0, 5.0, 15.0, 30.0, 45.0]:
		step_degrees = candidate
		if degrees_across / candidate <= 12.0:
			break
	var step_world := deg_to_rad(step_degrees) * circumference / TAU
	var mpp := _view_span_m / rect.size.x
	var left_world := _center.x - rect.size.x * mpp * 0.5
	var top_world := _center.y - rect.size.y * mpp * 0.5
	var first_x: float = ceilf(left_world / step_world) * step_world
	var first_z: float = ceilf(top_world / step_world) * step_world
	var x: float = first_x
	while x <= left_world + rect.size.x * mpp:
		var sx: float = rect.position.x + (x - left_world) / mpp
		draw_line(Vector2(sx, rect.position.y), Vector2(sx, rect.end.y),
			_with_alpha(Color(0.72, 0.91, 0.82, 0.12), alpha), 1.0)
		x += step_world
	var z: float = first_z
	while z <= top_world + rect.size.y * mpp:
		var sy: float = rect.position.y + (z - top_world) / mpp
		draw_line(Vector2(rect.position.x, sy), Vector2(rect.end.x, sy),
			_with_alpha(Color(0.72, 0.91, 0.82, 0.12), alpha), 1.0)
		z += step_world
	draw_string(_font, rect.position + Vector2(12, 24),
		"%.3f° %s   %.3f° %s" % [absf(rad_to_deg(center_geo.y)),
			"N" if center_geo.y >= 0.0 else "S", absf(rad_to_deg(center_geo.x)),
			"E" if center_geo.x >= 0.0 else "W"],
		HORIZONTAL_ALIGNMENT_LEFT, -1, 13,
		_with_alpha(Color(0.88, 0.97, 0.90, 0.86), alpha))


func _draw_local_markers(rect: Rect2, alpha := 1.0) -> void:
	for marker in markers_for_body(selected_body):
		var pos3: Vector3 = marker.position
		var base := world_to_screen(coordinates_for_position(pos3, selected_body))
		if not rect.grow(-7).has_point(base): continue
		var forward := projected_heading(marker)
		var side := forward.orthogonal()
		var polygon := PackedVector2Array([base + forward * 14, base - forward * 7 + side * 6, base - forward * 7 - side * 6])
		var color := _with_alpha(Color("ffe581") if marker.local else Color("58c8ff"), alpha)
		draw_colored_polygon(polygon, color)
		draw_polyline(polygon + PackedVector2Array([polygon[0]]), Color("13222b"), 2, true)
		_draw_marker_name(base + Vector2(0, -15), str(marker.name), color, alpha)


func _draw_marker_name(position: Vector2, marker_name: String, color: Color,
		alpha := 1.0) -> void:
	var width := maxf(_font.get_string_size(marker_name,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x + 12.0, 34.0)
	var panel := Rect2(position - Vector2(width * 0.5, 20.0), Vector2(width, 18.0))
	draw_style_box(_rounded_box(
		_with_alpha(Color(0.01, 0.03, 0.045, 0.82), alpha),
		color.darkened(0.2), 1, 6), panel)
	draw_string(_font, panel.position + Vector2(6, 13), marker_name,
		HORIZONTAL_ALIGNMENT_CENTER, width - 12.0, 11,
		_with_alpha(Color.WHITE, alpha))


func _draw_globe_view(alpha := 1.0, globe_scale := 1.0) -> void:
	var rect := map_rect()
	draw_rect(rect, _with_alpha(Color("0b1822"), alpha))
	var view_geo := world_xz_to_lon_lat(_center, body_circumference())
	var radius := minf(rect.size.y * .44, rect.size.x * .4) * globe_scale
	var center := rect.get_center()
	if selected_body == CelestialBody.EARTH:
		_draw_atmosphere(center, radius, alpha)
		_draw_textured_sphere(center, radius, view_geo, false, alpha)
		_draw_globe_markers(center, radius, view_geo, alpha)
	else:
		_draw_moon_sphere(center, radius, view_geo, alpha)
		_draw_moon_markers(center, radius, view_geo, alpha)
	_draw_globe_landmarks(center, radius, view_geo, alpha)
	draw_rect(rect, _with_alpha(Color("657b8a"), alpha), false, 1, true)


func _draw_atmosphere(center: Vector2, radius: float, alpha := 1.0) -> void:
	for ring in range(10, 0, -1):
		var t := float(ring) / 10.0
		draw_circle(center, radius + ring * 2.4,
			_with_alpha(Color(0.16, 0.57, 1.0,
				(1.0 - t) * 0.025 + 0.012), alpha))
	draw_arc(center, radius + 2.0, 0.0, TAU, 128,
		_with_alpha(Color(0.35, 0.78, 1.0, 0.82), alpha), 2.0, true)


func _draw_textured_sphere(center: Vector2, radius: float,
		view_lon_lat: Vector2, _moon := false, alpha := 1.0) -> void:
	_ensure_globe_atlas()
	if not _globe_texture:
		draw_circle(center, radius, _with_alpha(Color("1e6e8f"), alpha))
		return
	var mesh := _sphere_mesh_for_view(view_lon_lat)
	var transform := Transform2D(Vector2(radius, 0.0), Vector2(0.0, radius),
		center)
	draw_mesh(mesh, _globe_texture, transform, Color(1.0, 1.0, 1.0, alpha))
	draw_arc(center, radius, 0.0, TAU, 128,
		_with_alpha(Color(0.75, 0.91, 1.0, 0.62), alpha), 1.0, true)


## A globe is one cached canvas mesh draw, not hundreds of per-frame polygon
## calls. It is rebuilt only after a meaningful user rotation; atlas updates do
## not touch geometry. Repeated vertices keep each longitude seam explicit.
func _sphere_mesh_for_view(view_lon_lat: Vector2, lunar := false) -> ArrayMesh:
	if lunar:
		if _moon_sphere_mesh \
				and _moon_mesh_view.distance_squared_to(view_lon_lat) < 0.000004:
			return _moon_sphere_mesh
	elif _earth_sphere_mesh \
			and _earth_mesh_view.distance_squared_to(view_lon_lat) < 0.000004:
		return _earth_sphere_mesh
	var vertices := PackedVector3Array()
	var colors := PackedColorArray()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	var longitude_steps := GLOBE_LONGITUDE_STEPS
	var latitude_steps := GLOBE_LATITUDE_STEPS
	for lat_index in range(latitude_steps):
		var v0 := float(lat_index) / latitude_steps
		var v1 := float(lat_index + 1) / latitude_steps
		var lat0 := lerpf(PI * 0.5, -PI * 0.5, v0)
		var lat1 := lerpf(PI * 0.5, -PI * 0.5, v1)
		for lon_index in range(longitude_steps):
			var u0 := float(lon_index) / longitude_steps
			var u1 := float(lon_index + 1) / longitude_steps
			var lon0 := lerpf(-PI, PI, u0)
			var lon1 := lerpf(-PI, PI, u1)
			var geo := [Vector2(lon0, lat0), Vector2(lon1, lat0),
				Vector2(lon1, lat1), Vector2(lon0, lat1)]
			var projected: Array[Dictionary] = []
			var depth_sum := 0.0
			for coordinate in geo:
				var projection := globe_projection(coordinate, view_lon_lat,
					Vector2.ZERO, 1.0)
				projected.append(projection)
				depth_sum += float(projection.depth)
			if depth_sum <= 0.0:
				continue
			var shade := clampf(0.58 + depth_sum * 0.105, 0.48, 1.0)
			var quad_uvs := PackedVector2Array([
				Vector2(u0, v0), Vector2(u1, v0),
				Vector2(u1, v1), Vector2(u0, v1)])
			var first := vertices.size()
			for vertex_index in range(4):
				var point: Vector2 = projected[vertex_index].position
				vertices.append(Vector3(point.x, point.y, 0.0))
				uvs.append(quad_uvs[vertex_index])
				if lunar:
					var depth := float(projected[vertex_index].depth)
					var screen_normal := Vector3(point.x, point.y, depth).normalized()
					var diffuse := maxf(screen_normal.dot(
						MOON_LIGHT_SCREEN.normalized()), 0.0)
					var limb := lerpf(0.56, 1.0,
						smoothstep(0.0, 0.58, maxf(depth, 0.0)))
					var lunar_shade := clampf((0.16 + diffuse * 0.96) * limb,
						0.08, 1.08)
					colors.append(Color(lunar_shade * 1.02, lunar_shade,
						lunar_shade * 0.97, 1.0 if depth >= -0.03 else 0.0))
				else:
					colors.append(Color(shade, shade, shade, 1.0))
			indices.append_array(PackedInt32Array([
				first, first + 1, first + 2, first, first + 2, first + 3]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	if lunar:
		_moon_sphere_mesh = mesh
		_moon_mesh_view = view_lon_lat
	else:
		_earth_sphere_mesh = mesh
		_earth_mesh_view = view_lon_lat
	return mesh


## Generated lunar images are published exclusively by the map worker.
func _ensure_moon_atlas() -> void:
	pass


func _draw_moon_sphere(center: Vector2, radius: float,
		view_lon_lat: Vector2, alpha := 1.0) -> void:
	_ensure_moon_atlas()
	draw_circle(center, radius + maxf(3.0, radius * 0.018),
		_with_alpha(Color(0.55, 0.64, 0.77, 0.16), alpha))
	var mesh := _sphere_mesh_for_view(view_lon_lat, true)
	var transform := Transform2D(Vector2(radius, 0.0), Vector2(0.0, radius),
		center)
	if _moon_texture:
		draw_mesh(mesh, _moon_texture, transform, Color(1.0, 1.0, 1.0, alpha))
	else:
		draw_circle(center, radius, _with_alpha(Color("848997"), alpha))
	# Exact lunar relief is sampled once into the cached cartographic texture.
	draw_arc(center, radius, 0.0, TAU, 128,
		_with_alpha(Color(0.82, 0.88, 0.98, 0.72), alpha),
		maxf(1.0, radius * 0.004), true)
	draw_arc(center, radius - maxf(1.0, radius * 0.007), PI * 0.62,
		PI * 1.62, 72, _with_alpha(Color(0.98, 0.98, 0.94, 0.22), alpha),
		maxf(1.0, radius * 0.003), true)


func _draw_globe_markers(center: Vector2, radius: float,
		view_lon_lat: Vector2, alpha := 1.0) -> void:
	var circumference := planet_circumference_m()
	for marker in markers_for_body(CelestialBody.EARTH):
		var pos3: Vector3 = marker.position
		var geo := world_xz_to_lon_lat(Vector2(pos3.x, pos3.z), circumference)
		var projected := globe_projection(geo, view_lon_lat, center, radius)
		if not bool(projected.visible):
			continue
		var facing := marker_forward(float(marker.yaw))
		var ahead_world := Vector2(pos3.x, pos3.z) + facing \
			* PLAYER_MARKER_WORLD_LENGTH
		var ahead_geo := world_xz_to_lon_lat(ahead_world, circumference)
		var ahead := globe_projection(ahead_geo, view_lon_lat, center, radius)
		var ahead_position: Vector2 = ahead.position
		var projected_position: Vector2 = projected.position
		var direction: Vector2 = (ahead_position - projected_position).normalized()
		if direction.length_squared() < 0.1:
			direction = Vector2.UP
		var color := _with_alpha(
			Color("ffe581") if bool(marker.local) else Color("58c8ff"), alpha)
		draw_circle(projected.position, 5.5,
			_with_alpha(Color(0.01, 0.02, 0.04, 0.9), alpha))
		draw_circle(projected.position, 3.7, color)
		draw_line(projected.position, projected.position + direction * 11.0,
			color, 2.2, true)
		_draw_marker_name(projected.position + Vector2(0, -8), str(marker.name),
			color, alpha)


func _draw_moon_markers(center: Vector2, radius: float,
		view_lon_lat: Vector2, alpha := 1.0) -> void:
	for marker in markers_for_body(CelestialBody.MOON):
		var coordinate := coordinates_for_position(marker.position, CelestialBody.MOON)
		var projected := globe_projection(coordinate / MoonWorld.PLAYABLE_RADIUS_METERS, view_lon_lat, center, radius)
		if not projected.visible: continue
		var color := _with_alpha(Color("ffe581") if marker.local else Color("58c8ff"), alpha)
		draw_circle(projected.position, 5, color, true, -1, true)
		_draw_marker_name(projected.position + Vector2(0, -10), str(marker.name), color, alpha)


func _draw_chrome(blend: float) -> void:
	var rect := map_rect()
	draw_rect(Rect2(0, 0, size.x, HEADER_H), MenuTheme.INK)
	draw_line(Vector2(0, HEADER_H - 1), Vector2(size.x, HEADER_H - 1),
		MenuTheme.BORDER, 2.0)
	draw_string(_font, Vector2(MAP_MARGIN, 31), "World map",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 24, MenuTheme.TEXT)
	draw_string(_font, Vector2(MAP_MARGIN, 54),
		"Terrain, streets and destinations",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 11, MenuTheme.MUTED)
	var button_y := 18.0
	_earth_button_rect = Rect2(size.x - 426, button_y, 90, 38)
	_moon_button_rect = Rect2(size.x - 328, button_y, 90, 38)
	_home_button_rect = Rect2(size.x - 230, button_y, 110, 38)
	_close_button_rect = Rect2(size.x - 112, button_y, 88, 38)
	_draw_button(_earth_button_rect, "Earth",
		selected_body == CelestialBody.EARTH)
	_draw_button(_moon_button_rect, "Moon",
		selected_body == CelestialBody.MOON)
	_draw_button(_home_button_rect, "Recenter", false)
	_draw_button(_close_button_rect, "Close", false)
	draw_rect(Rect2(0, size.y - FOOTER_H, size.x, FOOTER_H),
		MenuTheme.INK)
	draw_line(Vector2(0, size.y - FOOTER_H),
		Vector2(size.x, size.y - FOOTER_H), MenuTheme.BORDER, 1.0)
	var footer := "Drag / WASD to pan   ·   Scroll to zoom   ·   Home to recenter   ·   X / Esc to close"
	draw_string(_font, Vector2(MAP_MARGIN, size.y - 40), footer,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 12, MenuTheme.MUTED)
	var right_status := ""
	if selected_body == CelestialBody.MOON:
		right_status = "MOON  ·  450 m PLAYABLE RADIUS  ·  SEEDED SURFACE"
	elif blend >= 0.52:
		right_status = "EARTH  •  %.0f km CIRCUMFERENCE" \
			% (planet_circumference_m() / 1000.0)
	else:
		var sample_geo := world_xz_to_lon_lat(_hover_world,
			planet_circumference_m())
		var elevation := float(_hover_sample.get("elevation", 0.0))
		var biome_name := ""
		var biome := int(_hover_sample.get("biome", -1))
		if biome >= 0 and Gen.has_method("biome_name"):
			biome_name = str(Gen.biome_name(biome)).to_upper() + "  •  "
		right_status = "%s%.0f m  •  %.2f° %s  %.2f° %s" % [biome_name,
			elevation, absf(rad_to_deg(sample_geo.y)),
			"N" if sample_geo.y >= 0.0 else "S",
			absf(rad_to_deg(sample_geo.x)),
			"E" if sample_geo.x >= 0.0 else "W"]
	draw_string(_font, Vector2(size.x - 620, size.y - 18), right_status,
		HORIZONTAL_ALIGNMENT_RIGHT, 590, 12, Color(0.64, 0.88, 1.0, 0.92))
	_draw_scale_bar(rect)


func _draw_button(rect: Rect2, text_value: String, active: bool) -> void:
	var hovered := rect.has_point(_hover_screen)
	var fill := MenuTheme.ACCENT if active else MenuTheme.INSET
	if hovered:
		fill = fill.lightened(0.10)
	draw_style_box(_rounded_box(fill,
		MenuTheme.ACCENT if active else MenuTheme.BORDER, 1, 8), rect)
	draw_string(_font, rect.position + Vector2(0, 25), text_value,
		HORIZONTAL_ALIGNMENT_CENTER, rect.size.x, 12,
		MenuTheme.INK if active else MenuTheme.TEXT)


func _draw_scale_bar(rect: Rect2) -> void:
	if globe_blend() >= 0.52:
		return
	var mpp := _view_span_m / rect.size.x
	var desired_world := mpp * 150.0
	var magnitude := pow(10.0, floor(log(desired_world) / log(10.0)))
	var normalized := desired_world / magnitude
	var nice := 1.0 if normalized < 2.0 else (2.0 if normalized < 5.0 else 5.0)
	var world_length := nice * magnitude
	var px_length := world_length / mpp
	var start := Vector2(rect.position.x + 18.0, rect.end.y - 24.0)
	draw_line(start, start + Vector2(px_length, 0), Color.WHITE, 3.0)
	draw_line(start + Vector2(0, -5), start + Vector2(0, 5), Color.WHITE, 2.0)
	draw_line(start + Vector2(px_length, -5), start + Vector2(px_length, 5),
		Color.WHITE, 2.0)
	var label := "%.0f km" % (world_length / 1000.0) if world_length >= 1000.0 \
		else "%.0f m" % world_length
	draw_string(_font, start + Vector2(0, -8), label,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color.WHITE)


static func _rounded_box(fill: Color, border: Color, border_width: int,
		radius: int) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = fill
	box.border_color = border
	box.set_border_width_all(border_width)
	box.set_corner_radius_all(radius)
	return box


## Read-only diagnostics used by the release gate.
func cache_diagnostics() -> Dictionary:
	return {
		"tiles": _tiles.size(),
		"queue": _bake_queue.size(),
		"required": _required_keys.size(),
		"last_local_samples": _last_baked_samples,
		"last_local_texture_uploads": _last_local_texture_uploads,
		"atlas_stage": _atlas_levels[0],
		"moon_atlas_stage": _atlas_levels[1],
		"worker_running": _worker.is_started(),
		"worker_samples": _last_worker_samples,
		"publish_usec": _last_publish_usec,
		"update_usec": _last_update_usec,
		"draw_usec": _last_draw_usec,
		"context": _context_signature,
		"source": "playable_generators",
		"source_caches": _source_cache_stats,
		"atlas_cursor": _globe_sample_cursor,
		"last_atlas_samples": _last_globe_baked_samples,
		"atlas_pixels": _globe_texture.get_width() * _globe_texture.get_height() \
			if _globe_texture else 0,
		"moon_atlas_pixels": _moon_texture.get_width() \
			* _moon_texture.get_height() if _moon_texture else 0,
		"earth_texture_id": _globe_texture.get_instance_id() \
			if _globe_texture else 0,
		"moon_texture_id": _moon_texture.get_instance_id() \
			if _moon_texture else 0,
		"moon_crater_stamps": 0,
		"moon_atlas_build_usec": 0,
		"moon_base_cursor": 0,
		"last_moon_base_samples": 0,
		"last_moon_crater_stamps": 0,
	}


func source_moon() -> MoonWorld:
	if is_instance_valid(world):
		var manager = world.get("expedition_manager")
		if is_instance_valid(manager) and is_instance_valid(manager.moon_world):
			return manager.moon_world
	if not is_instance_valid(_moon_probe): _moon_probe = MoonWorld.new()
	_moon_probe.moon_seed = Gen.world_seed ^ 0x4d4f4f4e
	return _moon_probe


func body_circumference() -> float:
	return TAU * MoonWorld.PLAYABLE_RADIUS_METERS if selected_body == CelestialBody.MOON \
		else planet_circumference_m()


func _select_body(body: int) -> void:
	if body == selected_body: return
	_cartography.cancelled = true
	_body_views[selected_body] = {"center": _target_center, "span": _target_span_m}
	selected_body = body
	var view: Dictionary = _body_views.get(body, {"center": Vector2.ZERO,
		"span": 600.0 if body == CelestialBody.MOON else 8000.0})
	_center = view.center
	_target_center = _center
	_target_span_m = view.span
	_view_span_m = _target_span_m
	_required_keys.clear()
	_landmark_timer = 0.0
	body_selected.emit(body)
	queue_redraw()


func coordinates_for_position(position3: Vector3, body: int) -> Vector2:
	if body == CelestialBody.MOON:
		var source := source_moon()
		return Cartography.lunar_coordinate(source.to_local(position3) - MoonWorld.PLAYABLE_CENTER) \
			if source.is_inside_tree() else Cartography.lunar_coordinate(position3 - MoonWorld.PLAYABLE_CENTER)
	return Gen.canonical_planet_xz(Vector2(position3.x, position3.z))


func position_for_coordinates(coordinate: Vector2, body: int) -> Vector3:
	if body == CelestialBody.MOON:
		var source := source_moon()
		var point := source.surface_position(Cartography.lunar_direction(coordinate))
		return source.to_global(point) if source.is_inside_tree() else point
	var p := Gen.canonical_planet_xz(coordinate)
	return Vector3(p.x, Gen.height(p.x, p.y), p.y)


func projected_heading(marker: Dictionary) -> Vector2:
	var p: Vector3 = marker.position
	if selected_body == CelestialBody.EARTH: return marker_forward(float(marker.yaw))
	var direction := Vector3.FORWARD
	if bool(marker.local) and is_instance_valid(world.local_player):
		direction = -world.local_player.rig.yaw_node.global_basis.z
	else:
		var source := source_moon()
		var up := (source.to_local(p) - MoonWorld.PLAYABLE_CENTER).normalized()
		direction = source.global_basis * (MoonWorld.surface_basis(up) * Basis(Vector3.UP, float(marker.yaw))).z * -1
	var here := coordinates_for_position(p, selected_body)
	var ahead := coordinates_for_position(p + direction * 2, selected_body)
	var delta := nearest_equivalent_xz(ahead, here, body_circumference()) - here
	return delta.normalized() if delta.length_squared() > .00001 else Vector2.UP


func _source_options() -> Dictionary:
	return {"seed": Gen.world_seed, "moon_seed": source_moon().moon_seed,
		"frontier": Gen.frontier_world, "debug": Gen.debug_world}


func _pump_worker() -> void:
	# Only completed immutable Images cross back to the canvas thread. One
	# texture publication per frame avoids a refinement-stage upload burst.
	if _worker.is_started():
		if _worker.is_alive():
			var irrelevant := int(_worker_job.body) != selected_body
			if _worker_job.kind == "atlas": irrelevant = irrelevant or globe_blend() < .01
			else: irrelevant = irrelevant or not _required_keys.has(_worker_job.key) or globe_blend() >= .995
			if irrelevant: _cartography.cancelled = true
			return
		var result: Dictionary = _worker.wait_to_finish()
		if result.is_empty() and _worker_job.get("kind") == "tile" and _tiles.has(_worker_job.get("key")) and not _bake_queue.has(str(_worker_job.key)):
			_bake_queue.append(str(_worker_job.key))
		if not result.is_empty() and str(result.job.signature) == _context_signature:
			var started := Time.get_ticks_usec()
			var job: Dictionary = result.job
			var image: Image = result.image
			_last_worker_samples = int(result.samples)
			_source_cache_stats = {"macro_entries": int(result.macro_cache_entries), "lunar_vertices": int(result.lunar_vertices)}
			if job.kind == "atlas":
				if int(job.body) == CelestialBody.EARTH: _globe_texture = ImageTexture.create_from_image(image)
				else: _moon_texture = ImageTexture.create_from_image(image)
				_atlas_levels[int(job.body)] = int(job.stage) + 1
			elif _tiles.has(job.key):
				var tile: Dictionary = _tiles[job.key]
				tile.image = image
				tile.texture = ImageTexture.create_from_image(image)
				tile.stage = int(job.stage) + 1
				_last_local_texture_uploads = 1
				if int(tile.stage) < LOCAL_PREVIEW_GRIDS.size() and not _bake_queue.has(str(job.key)): _bake_queue.append(str(job.key))
			_last_publish_usec = Time.get_ticks_usec() - started
	if not _open: return
	var job: Dictionary = {}
	var body := selected_body
	var atlas_stage: int = _atlas_levels[body]
	if globe_blend() > .01 and atlas_stage < _atlas_stages.size():
		var width: int = _atlas_stages[atlas_stage]
		var circumference := body_circumference()
		job = {"kind": "atlas", "body": body, "stage": atlas_stage,
			"resolution": Vector2i(width + 1, width / 2 + 1),
			"origin": Vector2(-circumference * .5, circumference * .25),
			"extent": Vector2(circumference, -circumference * .5)}
	elif globe_blend() < .995:
		_prioritize_bakes()
		for key in _bake_queue.duplicate():
			if not _required_keys.has(key) or not _tiles.has(key): continue
			var tile: Dictionary = _tiles[key]
			var stage: int = tile.stage
			if stage >= LOCAL_PREVIEW_GRIDS.size(): continue
			_bake_queue.erase(key)
			var tile_world := float(TILE_METERS_PER_PX[int(tile.tier)]) * TILE_PX
			var grid: int = LOCAL_PREVIEW_GRIDS[stage]
			job = {"kind": "tile", "key": key, "body": body, "stage": stage,
				"resolution": Vector2i.ONE * (grid + 1),
				"origin": Vector2(tile.key) * tile_world, "extent": Vector2.ONE * tile_world}
			break
	if job.is_empty(): return
	job.options = _source_options()
	job.signature = _context_signature
	_worker_job = job
	_cartography.cancelled = false
	_worker.start(_cartography.bake.bind(job))


func _exit_tree() -> void:
	_cartography.cancelled = true
	if _worker.is_started(): _worker.wait_to_finish()
	_cartography.dispose()
	if is_instance_valid(_moon_probe): _moon_probe.free()


func _frontier() -> Node:
	if not is_instance_valid(world): return null
	var main := world.get_parent()
	return main.get("frontier_controller") if is_instance_valid(main) else null


func landmark_snapshot() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if selected_body == CelestialBody.EARTH:
		if Gen.airstrip_valid:
			result.append({"id": "spaceport", "label": "Spaceport", "coordinate": Gen.airstrip_center,
				"kind": "port", "priority": 1})
			var launch := Gen.rocket_launch_position()
			result.append({"id": "launch", "label": "Launch pad", "coordinate": Vector2(launch.x, launch.z), "kind": "port", "priority": 3})
		if Gen.frontier_world:
			result.append({"id": "crownreach", "label": "Crownreach · 30.1 sq mi", "coordinate": Plan.CENTER, "kind": "city", "priority": 0})
			result.append({"id": "gardens", "label": "Lantern Gardens", "coordinate": Plan.PARK_CENTER, "kind": "park", "priority": 1})
			for id: String in Towns.EARTH_ORIGINS:
				result.append({"id": id, "label": str(FrontierSocieties.NAMES[id][0]), "coordinate": Towns.EARTH_ORIGINS[id], "kind": "town", "priority": 1})
			for stop in Plan.stops():
				var p: Vector3 = stop.position
				result.append({"id": "transit:" + str(stop.id), "label": str(stop.name), "coordinate": Vector2(p.x, p.z), "kind": "transit", "priority": 4})
	else:
		result.append({"id": "landing", "label": "Landing pad", "coordinate": Vector2.ZERO, "kind": "port", "priority": 1})
		for definition in [["farm", "Cheese farm"], ["market", "Crater & Curd"], ["aging", "Aging cellar"], ["observatory", "Observatory"], ["relay", "Oxygen relay"], ["crystal_garden", "Crystal garden"]]:
			result.append({"id": str(definition[0]), "label": str(definition[1]),
				"coordinate": Cartography.lunar_coordinate(MoonColony.facility_direction(definition[0])), "kind": "colony", "priority": 2})
		if Gen.frontier_world:
			for id: String in Towns.MOON_DIRECTIONS:
				result.append({"id": "moon:" + id, "label": str(FrontierSocieties.NAMES[id][1]),
					"coordinate": Cartography.lunar_coordinate(Towns.MOON_DIRECTIONS[id]), "kind": "town", "priority": 1})
	var frontier := _frontier()
	if is_instance_valid(frontier):
		var waypoints: Array = [frontier.waypoint]
		if is_instance_valid(frontier.city): waypoints.append(frontier.city.waypoint)
		for waypoint: Dictionary in waypoints:
			if waypoint.is_empty() or not waypoint.get("position") is Vector3: continue
			var realm_body := CelestialBody.MOON if frontier.current_planet() == "moon" else CelestialBody.EARTH
			if realm_body == selected_body:
				result.push_front({"id": "waypoint", "label": str(waypoint.get("label", "Destination")),
					"coordinate": coordinates_for_position(waypoint.position, selected_body), "kind": "waypoint", "priority": 0})
		var settlement: Node = frontier.moon_settlement if selected_body == CelestialBody.MOON else frontier.earth_settlement
		if is_instance_valid(settlement) and settlement.is_build_complete():
			for entry: Dictionary in settlement.get_interactions():
				if str(entry.kind) not in ["facility", "market", "board"]: continue
				result.append({"id": "site:" + str(entry.id), "label": str(entry.label),
					"coordinate": coordinates_for_position(entry.position, selected_body), "kind": "service", "priority": 5})
	if selected_body == CelestialBody.MOON and Net.player_realm() == Net.PlayerRealm.MOON:
		var manager = world.get("expedition_manager") if is_instance_valid(world) else null
		if is_instance_valid(manager) and is_instance_valid(manager.moon_world.colony_world):
			var waypoint: Dictionary = manager._colony_waypoint
			var target: Vector3 = manager.moon_world.colony_world.interaction_position(str(waypoint.action), int(waypoint.target))
			result.push_front({"id": "lunar_waypoint", "label": str(waypoint.title),
				"coordinate": coordinates_for_position(target, selected_body), "kind": "waypoint", "priority": 0})

	return result


func city_footprints(bounds: Rect2) -> Array[Dictionary]:
	if bounds == _footprint_view_bounds: return _footprint_view
	var result: Array[Dictionary] = []
	var municipal:=Rect2(Vector2(Plan.MIN_X,Plan.MIN_Z),Vector2(Plan.MAX_X-Plan.MIN_X,Plan.MAX_Z-Plan.MIN_Z))
	if not bounds.intersects(municipal):return result
	var query:=bounds.intersection(municipal)
	var a := Plan.world_to_block(query.position)
	var b := Plan.world_to_block(query.end.clamp(Vector2(Plan.MIN_X,Plan.MIN_Z),Vector2(Plan.MAX_X,Plan.MAX_Z)))
	for x in range(maxi(0, a.x), mini(Plan.GRID_WIDTH - 1, b.x) + 1):
		for z in range(maxi(0, a.y), mini(Plan.GRID_DEPTH - 1, b.y) + 1):
			var key := Vector2i(x, z)
			if not _outline_blocks.has(key): _outline_blocks[key] = Plan.block_buildings(key)
			for building: Dictionary in _outline_blocks[key]:
				var size3: Vector3 = building.size
				var p3: Vector3 = building.position
				var footprint := Rect2(Vector2(p3.x - size3.x * .5, p3.z - size3.z * .5), Vector2(size3.x, size3.z))
				if bounds.intersects(footprint):
					result.append({"id": building.id, "rect": footprint, "height": size3.y, "kind": building.kind})
	# The near urban overlay is limited to a few hundred visible blocks, never
	# retained as another 36,861-building city graph after repeated browsing.
	if _outline_blocks.size() > 256:
		var retained: Dictionary = {}
		for key in _outline_blocks:
			if key.x >= a.x and key.x <= b.x and key.y >= a.y and key.y <= b.y: retained[key] = _outline_blocks[key]
		_outline_blocks = retained
	_footprint_view_bounds = bounds
	_footprint_view = result
	return result


func _vector_line(a: Vector2, b: Vector2, color: Color, width: float) -> void:
	# Clip before drawing so a crossing road cannot obscure the atlas controls.
	var points := Geometry2D.intersect_polyline_with_polygon(PackedVector2Array([a, b]),
		PackedVector2Array([map_rect().position, Vector2(map_rect().end.x, map_rect().position.y), map_rect().end, Vector2(map_rect().position.x, map_rect().end.y)]))
	for line in points:
		if line.size() >= 2: draw_polyline(line, color, maxf(width, 1.0), true)


func _map_rect_shape(bounds: Rect2, fill: Color, outline: Color) -> void:
	var start := world_to_screen(bounds.position)
	var projected := Rect2(start, world_to_screen(bounds.end) - start).abs()
	var clipped := projected.intersection(map_rect())
	if not clipped.has_area(): return
	draw_rect(clipped, fill)
	draw_rect(clipped, outline, false, 1.0, true)


func feature_query_bounds() -> Rect2:
	# Terrain may be viewed in an unfolded longitude/pole copy. Query authored
	# geometry in canonical coordinates and project it back through that copy.
	var extent := map_rect().size * _view_span_m / map_rect().size.x
	return Rect2(canonical_planet_xz(_center, body_circumference()) - extent * .5, extent)


func _draw_cartographic_features(rect: Rect2, alpha: float) -> void:
	var mpp := _view_span_m / rect.size.x
	var world_bounds := feature_query_bounds()
	if selected_body == CelestialBody.EARTH:
		if Gen.frontier_world:
			var city_bounds := Rect2(Plan.MIN_X, Plan.MIN_Z, Plan.MAX_X - Plan.MIN_X, Plan.MAX_Z - Plan.MIN_Z)
			if world_bounds.intersects(city_bounds):
				_map_rect_shape(city_bounds, _with_alpha(Color("c9ceca"), alpha), _with_alpha(Color("687c81"), alpha))
				if _view_span_m < 28000:
					for i in range(Plan.GRID_WIDTH + 1):
						var x := Plan.MIN_X + i * Plan.BLOCK_EXTENTS.x
						_vector_line(world_to_screen(Vector2(x,Plan.MIN_Z)),world_to_screen(Vector2(x,Plan.MAX_Z)),_with_alpha(Color("eef1e6"),alpha),24/mpp)
					for i in range(Plan.GRID_DEPTH + 1):
						var z := Plan.MIN_Z + i * Plan.BLOCK_EXTENTS.y
						_vector_line(world_to_screen(Vector2(Plan.MIN_X,z)),world_to_screen(Vector2(Plan.MAX_X,z)),_with_alpha(Color("eef1e6"),alpha),24/mpp)
				if _view_span_m < 2200:
					for road in city_minor_roads(world_bounds):
						_vector_line(world_to_screen(road.a), world_to_screen(road.b), _with_alpha(Color("edf0e4"), alpha), Plan.LOCAL_ROAD_HALF_WIDTH * 2 / mpp)
				if _view_span_m < 2200:
					for footprint in city_footprints(world_bounds):
						var tint := Color("8e9b9f").lerp(Color("425d73"), clampf(float(footprint.height) / 650.0, 0, 1))
						_map_rect_shape(footprint.rect, _with_alpha(tint, alpha), _with_alpha(Color("647680"), alpha))
				var park := Rect2(Plan.PARK_CENTER - Plan.PARK_HALF_EXTENTS, Plan.PARK_HALF_EXTENTS * 2)
				_map_rect_shape(park, _with_alpha(Color("88b783"), alpha), _with_alpha(Color("659762"), alpha))
				var pond := PackedVector2Array()
				for i in range(65): pond.append(world_to_screen(Plan.pond_shore(i * TAU / 64)))
				var clip_polygon := PackedVector2Array([rect.position, Vector2(rect.end.x, rect.position.y), rect.end, Vector2(rect.position.x, rect.end.y)])
				for visible_pond in Geometry2D.intersect_polygons(pond, clip_polygon):
					draw_colored_polygon(visible_pond, _with_alpha(Color("579aa8"), alpha))
					draw_polyline(visible_pond + PackedVector2Array([visible_pond[0]]), _with_alpha(Color("386e89"), alpha), 1.5, true)

			for road: Array in Towns.CONNECTING_ROADS:
				for i in range(road.size() - 1): _vector_line(world_to_screen(road[i]), world_to_screen(road[i + 1]), _with_alpha(Color("dedbb5"), alpha), Towns.ROAD_HALF_WIDTH * 2 / mpp)
			_vector_line(world_to_screen(Vector2(930, 0)), world_to_screen(Vector2(Plan.MIN_X, 0)), _with_alpha(Color("eee8c6"), alpha), 24 / mpp)
			if _view_span_m < 120000:
				for road in Highways.roads():
					if road.kind!="divided" and _view_span_m>18000:continue
					var points:PackedVector3Array=road.points
					for i in range(points.size()-1):
						var a:=Vector2(points[i].x,points[i].z)
						var b:=Vector2(points[i+1].x,points[i+1].z)
						if not world_bounds.grow(30).has_point(a) and not world_bounds.grow(30).has_point(b):continue
						_vector_line(world_to_screen(a),world_to_screen(b),_with_alpha(Color("efb951") if road.kind=="divided" else Color("dfd8ad"),alpha),maxf(1.5,float(road.half_width)*2/mpp))
				if _view_span_m<40000:
					for access in Highways.access_points():
						var coordinate:=Vector2(access.position.x,access.position.z)
						if world_bounds.has_point(coordinate):_draw_feature_label(world_to_screen(coordinate),("H-2" if access.id=="settlement" else "EXIT "+str(access.id))+" · "+str(access.name),Color("f2c970"),alpha)
		if _view_span_m < 30000:
			for route: Dictionary in _source_roads:
				if not world_bounds.intersects(route.bounds): continue
				var points: PackedVector2Array = route.points
				for i in range(points.size() - 1):
					_vector_line(world_to_screen(points[i]), world_to_screen(points[i + 1]), _with_alpha(Color("dfd5b0"), alpha), Gen.ROAD_HALF_WIDTH * 2 / mpp)
		if Gen.airstrip_valid and _view_span_m < 90000:
			var axis := Vector2(sin(Gen.airstrip_heading), cos(Gen.airstrip_heading))
			_vector_line(world_to_screen(Gen.airstrip_center - axis * Gen.AIRSTRIP_LENGTH * .5), world_to_screen(Gen.airstrip_center + axis * Gen.AIRSTRIP_LENGTH * .5), _with_alpha(Color("555d67"), alpha), maxf(3, Gen.AIRSTRIP_WIDTH / mpp))
			if _view_span_m < 12000:
				for feature in airfield_footprints():
					var polygon := PackedVector2Array()
					for corner: Vector2 in feature.polygon: polygon.append(world_to_screen(corner))
					var clip := PackedVector2Array([rect.position, Vector2(rect.end.x, rect.position.y), rect.end, Vector2(rect.position.x, rect.end.y)])
					for part in Geometry2D.intersect_polygons(polygon, clip):
						draw_colored_polygon(part, _with_alpha(Color("88979c"), alpha))
						draw_polyline(part + PackedVector2Array([part[0]]), _with_alpha(Color("4b6574"), alpha), 1.2, true)

	for landmark in _landmark_cache:
		var priority: int = landmark.priority
		if priority >= 4 and _view_span_m > 7000: continue
		if priority >= 5 and _view_span_m > 1800: continue
		if priority >= 2 and _view_span_m > 90000 and selected_body == CelestialBody.EARTH: continue
		var point := world_to_screen(landmark.coordinate)
		if not rect.grow(-12).has_point(point): continue
		var color := Color("f6d47e") if landmark.kind == "waypoint" else Color("173e59")
		draw_circle(point, 4.2 if priority < 2 else 3.0, _with_alpha(color, alpha), true, -1, true)
		_draw_feature_label(point, str(landmark.label), color, alpha)


func _draw_feature_label(point: Vector2, label: String, color: Color, alpha: float) -> void:
	var width := _font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x + 14
	for offset in [Vector2(9, -16), Vector2(-width - 9, -16), Vector2(9, 12), Vector2(-width - 9, 12), Vector2(9, -44), Vector2(-width - 9, -44), Vector2(9, 40), Vector2(-width - 9, 40)]:
		var area := Rect2(point + offset, Vector2(width, 23))
		if not map_rect().encloses(area): continue
		var overlaps := false
		for used in _label_rects:
			if area.grow(3).intersects(used):
				overlaps = true
				break
		if overlaps: continue
		_label_rects.append(area)
		if absf(offset.y) > 25:
			var end := Vector2(clampf(point.x, area.position.x, area.end.x), clampf(point.y, area.position.y, area.end.y))
			draw_line(point, end, _with_alpha(color, alpha * .65), 1.0, true)
		draw_style_box(_rounded_box(_with_alpha(Color("f3f0df"), alpha * .94), _with_alpha(Color("a5b4b4"), alpha), 1, 5), area)
		draw_string(_font, area.position + Vector2(7, 16), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, _with_alpha(color, alpha))
		return


func _draw_globe_landmarks(center: Vector2, radius: float, geo: Vector2, alpha: float) -> void:
	for landmark in _landmark_cache:
		if int(landmark.priority) > 1: continue
		var angle: Vector2 = landmark.coordinate * TAU / body_circumference()
		var projected := globe_projection(angle, geo, center, radius)
		if not projected.visible: continue
		draw_circle(projected.position, 3, _with_alpha(Color("f0ce76"), alpha), true, -1, true)
		_draw_feature_label(projected.position, str(landmark.label), Color("173e59"), alpha)


func city_minor_roads(_bounds: Rect2) -> Array[Dictionary]:
	# Rectangular city blocks contain rear courts, not an internal road lattice.
	return []


func airfield_footprints() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for hangar: Dictionary in Gen.airstrip_hangar_layout():
		var polygon := PackedVector2Array()
		var dimensions: Vector3 = hangar.size
		var transform := Transform3D(Basis(Vector3.UP, float(hangar.yaw)), hangar.pos)
		for corner in [Vector3(-.5, 0, -.5), Vector3(.5, 0, -.5), Vector3(.5, 0, .5), Vector3(-.5, 0, .5)]:
			var point: Vector3 = transform * (corner * dimensions)
			polygon.append(Vector2(point.x, point.z))
		result.append({"id": hangar.id, "polygon": polygon})
	return result
