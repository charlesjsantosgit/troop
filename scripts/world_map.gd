class_name WorldMap
extends Control
## Full-screen, spherical world atlas. Close local zooms reuse the same analytic
## Gen fields as the terrain instead of a second camera; distant zooms use
## imported 4K equirectangular atlases wrapped onto interactive globes. Local
## tile baking remains incremental and keeps a strict per-frame sampling budget.
## A transparent satellite micro-detail plate gives every new tile crisp natural
## texture immediately while the low-frequency live terrain mask refines.

signal opened
signal closed
signal body_selected(body: int)

enum CelestialBody { EARTH, MOON }

const EARTH_CIRCUMFERENCE_FALLBACK := 40_075_016.686
const MOON_CIRCUMFERENCE_M := 10_921_000.0
const TILE_PX := 320
const TILE_METERS_PER_PX := [2.0, 8.0, 32.0, 128.0, 512.0, 2048.0,
	8192.0]
const CACHE_TILE_LIMIT := 64
const LOCAL_BAKE_SAMPLES_PER_FRAME := 64
const LOCAL_SAMPLES_PER_TILE_TURN := 12
# Kept as a compatibility diagnostic: imported atlases perform zero runtime
# terrain samples, so the actual value reported each frame is always zero.
const GLOBE_BAKE_SAMPLES_PER_FRAME := 64
const BAKE_TIME_BUDGET_USEC := 1800
# Thirty-two live samples across a 320 px tile preserve coast, biome, height and
# road silhouettes. Fine satellite texture comes from the shared overlay below,
# avoiding the old 34,284 expensive Gen samples per tile.
const LOCAL_PREVIEW_GRIDS := [2, 4, 8, 16, 32]
const GLOBE_ATLAS_SIZE := Vector2i(4096, 2048)
const MOON_ATLAS_SIZE := Vector2i(4096, 2048)
const GLOBE_LONGITUDE_STEPS := 96
const GLOBE_LATITUDE_STEPS := 48
const EARTH_ATLAS: Texture2D = preload(
	"res://assets/textures/pangaea_earth_4k.jpg")
const MOON_ATLAS: Texture2D = preload(
	"res://assets/textures/lunar_surface_4k.jpg")
const SATELLITE_DETAIL_OVERLAY: Texture2D = preload(
	"res://assets/textures/satellite_microdetail_overlay.png")
const MOON_LIGHT_SCREEN := Vector3(-0.42, -0.30, 0.855)
const MIN_VIEW_SPAN_M := 320.0
const GLOBE_BLEND_START_FRACTION := 0.075
const GLOBE_FULL_FRACTION := 0.18
const MAX_VIEW_SPAN_FRACTION := 1.08
const HEADER_H := 72.0
const FOOTER_H := 48.0
const MAP_MARGIN := 24.0
const ZOOM_RESPONSE := 12.0
const PAN_RESPONSE := 14.0
const HOVER_SAMPLE_SECONDS := 0.12
const PLAYER_MARKER_WORLD_LENGTH := 90.0
# The playable 768 m lunar landing zone is presented as a readable patch on the
# near side of the selected Moon. This is a display projection only: marker
# membership still comes exclusively from Net's authority-replicated realm.
const MOON_MARKER_PATCH_ANGULAR_EXTENT := 0.42

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
var _satellite_detail_image: Image

# Both globe atlases are imported once and shared through Godot's resource
# cache. They never invoke Gen or allocate/copy an 8.4-million-pixel Image at
# runtime; only the nearby analytic terrain tiles use the bounded CPU baker.
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
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_ALL
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	visible = false
	set_process(false)
	set_process_input(false)


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
	if world and world.get("local_player"):
		var p: Node3D = world.get("local_player")
		_center = Vector2(p.global_position.x, p.global_position.z)
		_target_center = _center
	_target_span_m = clampf(_target_span_m, MIN_VIEW_SPAN_M,
		planet_circumference_m() * MAX_VIEW_SPAN_FRACTION)
	_view_span_m = _target_span_m
	grab_focus()
	queue_redraw()
	opened.emit()


func close_map() -> void:
	if not _open:
		return
	_open = false
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
	selected_body = CelestialBody.EARTH
	body_selected.emit(selected_body)
	queue_redraw()


func focus_moon() -> void:
	# Resolve the shared imported atlas before the first destination frame.
	_sync_seed()
	_ensure_moon_atlas()
	selected_body = CelestialBody.MOON
	_target_span_m = maxf(_target_span_m,
		planet_circumference_m() * GLOBE_FULL_FRACTION)
	body_selected.emit(selected_body)
	queue_redraw()


func recenter_on_player() -> void:
	if not world or not world.get("local_player"):
		return
	var p: Node3D = world.get("local_player")
	var destination := Vector2(p.global_position.x, p.global_position.z)
	# Select the equivalent unwrapped representation closest to the current
	# centre. Recentring near the date line therefore glides instead of jumping.
	_target_center = nearest_equivalent_xz(destination, _center,
		planet_circumference_m())
	selected_body = CelestialBody.EARTH


func _process(dt: float) -> void:
	if not _open:
		return
	_sync_seed()
	var circumference := planet_circumference_m()
	_target_span_m = clampf(_target_span_m, MIN_VIEW_SPAN_M,
		circumference * MAX_VIEW_SPAN_FRACTION)
	var pan_weight := 1.0 - exp(-PAN_RESPONSE * dt)
	_center = _center.lerp(_target_center, pan_weight)
	var zoom_weight := 1.0 - exp(-ZOOM_RESPONSE * dt)
	_view_span_m = exp(lerpf(log(maxf(_view_span_m, 1.0)),
		log(maxf(_target_span_m, 1.0)), zoom_weight))
	_keyboard_pan(dt)
	var globe_amount := globe_blend()
	_last_baked_samples = 0
	_last_globe_baked_samples = 0
	if selected_body == CelestialBody.EARTH and globe_amount < 0.995:
		_request_visible_tiles()
		_bake_local_samples(LOCAL_BAKE_SAMPLES_PER_FRAME)
	if globe_amount > 0.0 or selected_body == CelestialBody.MOON:
		_bake_globe_samples(GLOBE_BAKE_SAMPLES_PER_FRAME)
	if selected_body == CelestialBody.MOON or globe_amount > 0.0:
		_ensure_moon_atlas()
	_update_hover(dt)
	queue_redraw()


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
	if selected_body == CelestialBody.MOON and factor < 1.0:
		# Moon surface mapping is a future mission layer; keep this release on its
		# honest globe view rather than presenting invented local coordinates.
		return
	var rect := map_rect()
	var old_span := _target_span_m
	var maximum := planet_circumference_m() * MAX_VIEW_SPAN_FRACTION
	var new_span := clampf(old_span * factor, MIN_VIEW_SPAN_M, maximum)
	if selected_body == CelestialBody.EARTH and rect.has_point(screen_point):
		_target_center = zoom_anchored_center(_target_center, screen_point,
			rect, old_span, new_span)
	_target_span_m = new_span


func map_rect() -> Rect2:
	return Rect2(MAP_MARGIN, HEADER_H,
		maxf(size.x - MAP_MARGIN * 2.0, 1.0),
		maxf(size.y - HEADER_H - FOOTER_H, 1.0))


func globe_blend() -> float:
	var circumference := planet_circumference_m()
	return smoothstep(circumference * GLOBE_BLEND_START_FRACTION,
		circumference * GLOBE_FULL_FRACTION, _view_span_m)


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
	var script: Script = Gen.get_script()
	if script:
		var constants: Dictionary = script.get_script_constant_map()
		for key in ["PLANET_CIRCUMFERENCE_M", "PLANET_CIRCUMFERENCE",
				"WORLD_CIRCUMFERENCE_M"]:
			if constants.has(key):
				var value := float(constants[key])
				if value > 1000.0:
					return value
	if Gen.has_method("planet_circumference_m"):
		var queried := float(Gen.call("planet_circumference_m"))
		if queried > 1000.0:
			return queried
	return EARTH_CIRCUMFERENCE_FALLBACK


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
	var candidates: Array[Vector2] = []
	for longitude_copy in range(-1, 2):
		candidates.append(Vector2(p.x + float(longitude_copy) * c, p.y))
		candidates.append(Vector2(p.x + c * 0.5 + float(longitude_copy) * c,
			c * 0.5 - p.y))
		candidates.append(Vector2(p.x + c * 0.5 + float(longitude_copy) * c,
			-c * 0.5 - p.y))
	var best := candidates[0]
	var best_distance := best.distance_squared_to(reference)
	for candidate in candidates:
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


## Project the bounded playable landing zone around the currently displayed
## lunar hemisphere. Positive world Z remains down-screen, matching the local
## Earth atlas, so the same yaw arrow remains truthful in either realm.
static func moon_marker_lon_lat(position: Vector3,
		view_lon_lat := Vector2.ZERO) -> Vector2:
	var half_extent := maxf(float(MoonWorld.TERRAIN_HALF_EXTENT), 1.0)
	var normalized_x := clampf(position.x / half_extent, -1.0, 1.0)
	var normalized_z := clampf(position.z / half_extent, -1.0, 1.0)
	var latitude := clampf(view_lon_lat.y \
		- normalized_z * MOON_MARKER_PATCH_ANGULAR_EXTENT,
		-PI * 0.5 + 0.001, PI * 0.5 - 0.001)
	var longitude_scale := maxf(cos(view_lon_lat.y), 0.35)
	var longitude := wrapf(view_lon_lat.x \
		+ normalized_x * MOON_MARKER_PATCH_ANGULAR_EXTENT / longitude_scale,
		-PI, PI)
	return Vector2(longitude, latitude)


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
	var min_key := Vector2i(floori((center.x - half_world.x) / tile_world) - 1,
		floori((center.y - half_world.y) / tile_world) - 1)
	var max_key := Vector2i(floori((center.x + half_world.x) / tile_world) + 1,
		floori((center.y + half_world.y) / tile_world) + 1)
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


func _map_sample(point: Vector2, meters_per_pixel: float) -> Dictionary:
	var canonical := _canonical_sample_xz(point)
	if Gen.has_method("map_sample"):
		var generated: Variant = Gen.call("map_sample", canonical.x, canonical.y,
			meters_per_pixel)
		if generated is Dictionary and generated.has("color"):
			return generated
	# PlanetTerrain exposes value-only companions so a map pixel can reuse one
	# macro sample for height and biome. This avoids the several repeated 3D
	# noise evaluations in the ordinary gameplay convenience functions.
	if Gen.has_method("planet_terrain_sample") \
			and Gen.has_method("planet_height_from_sample") \
			and Gen.has_method("planet_biome_from_sample"):
		var macro: Dictionary = Gen.call("planet_terrain_sample", canonical.x,
			canonical.y)
		var sampled_elevation := float(Gen.call("planet_height_from_sample", macro))
		var sampled_biome := int(Gen.call("planet_biome_from_sample", macro,
			sampled_elevation))
		var road_sample: Dictionary = Gen.call("road_surface_sample", canonical.x,
			canonical.y) if Gen.has_method("road_surface_sample") else {}
		var road_strength := float(road_sample.get("grade", 0.0))
		var sampled_water := sampled_elevation < Gen.WATER_Y \
			or sampled_biome in [Gen.Biome.OCEAN, Gen.Biome.LAKE]
		var sampled_color := _map_ground_palette(sampled_elevation,
			sampled_biome, macro, road_sample)
		var sampled_canopy := _map_tree_cover(sampled_elevation, sampled_biome,
			road_strength)
		return {
			"color": sampled_color,
			"elevation": sampled_elevation,
			"water": sampled_water,
			"road": road_strength,
			"tree_cover": sampled_canopy,
			"biome": sampled_biome,
		}
	var elevation := Gen.height(canonical.x, canonical.y)
	var water := elevation < Gen.WATER_Y
	var color: Color
	if water:
		var depth := clampf((Gen.WATER_Y - elevation) / 120.0, 0.0, 1.0)
		color = Color("287fa9").lerp(Color("082d58"), depth)
	else:
		color = Gen.ground_color(elevation, canonical.x, canonical.y)
	var road := float(Gen.road_grade(canonical.x, canonical.y)) \
		if Gen.has_method("road_grade") else 0.0
	var tree_cover := float(Gen.canopy_cover(elevation, canonical.x,
		canonical.y)) if Gen.has_method("canopy_cover") else 0.0
	return {
		"color": color,
		"elevation": elevation,
		"water": water,
		"road": road,
		"tree_cover": tree_cover,
		"biome": Gen.biome_at_height(canonical.x, canonical.y, elevation)
			if Gen.has_method("biome_at_height") else -1,
	}


func _map_ground_palette(elevation: float, biome: int, macro: Dictionary,
		road_sample: Dictionary) -> Color:
	var detail := float(macro.get("detail", 0.0))
	if elevation < Gen.WATER_Y or biome in [Gen.Biome.OCEAN, Gen.Biome.LAKE]:
		var depth := clampf((Gen.WATER_Y - elevation) / 360.0, 0.0, 1.0)
		var water := Color("247fa8").lerp(Color("082b58"), depth * 0.88)
		if biome == Gen.Biome.LAKE:
			water = water.lerp(Color("3191a8"), 0.30)
		return water
	var low := Color(0.085, 0.26, 0.08)
	var high := Color(0.035, 0.155, 0.06)
	match biome:
		Gen.Biome.BAMBOO_GROVE:
			low = Color(0.14, 0.30, 0.075)
			high = Color(0.065, 0.19, 0.05)
		Gen.Biome.WETLAND:
			low = Color(0.095, 0.225, 0.09)
			high = Color(0.045, 0.14, 0.08)
		Gen.Biome.HIGHLAND:
			low = Color(0.075, 0.215, 0.10)
			high = Color(0.035, 0.13, 0.085)
		Gen.Biome.PLAINS:
			low = Color(0.34, 0.43, 0.13)
			high = Color(0.21, 0.31, 0.105)
		Gen.Biome.GRASSLAND:
			low = Color(0.23, 0.42, 0.10)
			high = Color(0.12, 0.29, 0.075)
		Gen.Biome.ROCKY_MOUNTAINS:
			low = Color(0.30, 0.285, 0.25)
			high = Color(0.42, 0.405, 0.38)
		Gen.Biome.DESERT:
			low = Color(0.67, 0.46, 0.22)
			high = Color(0.53, 0.34, 0.17)
		Gen.Biome.TUNDRA:
			low = Color(0.37, 0.40, 0.29)
			high = Color(0.27, 0.31, 0.27)
		Gen.Biome.ICE:
			low = Color(0.73, 0.81, 0.85)
			high = Color(0.88, 0.92, 0.94)
	var altitude_mix := clampf((elevation - 5.0) / 850.0, 0.0, 1.0)
	var color := low.lerp(high, altitude_mix)
	var rock := smoothstep(float(Gen.TREE_LINE) * 0.7,
		float(Gen.SNOW_LINE_START), elevation)
	color = color.lerp(Color(0.31, 0.28, 0.245), rock)
	var snow := smoothstep(float(Gen.SNOW_LINE_START),
		float(Gen.SNOW_LINE_FULL), elevation)
	color = color.lerp(Color(0.84, 0.88, 0.92), snow)
	var road := float(road_sample.get("grade", 0.0))
	if road > 0.12:
		var dirt := Color(0.39 + detail * 0.01, 0.285, 0.16)
		color = color.lerp(dirt, smoothstep(0.12, 0.78, road))
	return Color(color.r + detail * 0.018, color.g + detail * 0.018,
		color.b + detail * 0.018)


func _map_tree_cover(elevation: float, biome: int,
		road_strength: float) -> float:
	if road_strength > 0.12 or elevation < Gen.WATER_Y + 0.5 \
			or elevation > Gen.TREE_LINE:
		return 0.0
	var density := 0.0
	match biome:
		Gen.Biome.RAINFOREST: density = 0.95
		Gen.Biome.BAMBOO_GROVE: density = 0.90
		Gen.Biome.WETLAND: density = 0.72
		Gen.Biome.HIGHLAND: density = 0.82
		Gen.Biome.PLAINS: density = 0.20
		Gen.Biome.GRASSLAND: density = 0.32
		Gen.Biome.ROCKY_MOUNTAINS: density = 0.10
		Gen.Biome.DESERT: density = 0.025
		Gen.Biome.TUNDRA: density = 0.08
	var shore := smoothstep(Gen.WATER_Y + 0.5, Gen.WATER_Y + 1.6, elevation)
	var tree_line := 1.0 - smoothstep(Gen.TREE_LINE - 5.0,
		Gen.TREE_LINE, elevation)
	return shore * tree_line * density


## Whole-planet pixels do not need centimetre-scale runway grading or literal
## tree rolls. One coherent PlanetTerrain sample is enough to classify ocean,
## lake, climate, ice and mountain bands, keeping diagnostic overview samples
## cheaper and more truthful than repeating local decoration queries.
func _planet_overview_sample(point: Vector2) -> Dictionary:
	if not Gen.has_method("planet_terrain_sample"):
		return _map_sample(point, planet_circumference_m() /
			float(GLOBE_ATLAS_SIZE.x))
	var canonical := _canonical_sample_xz(point)
	var macro: Dictionary = Gen.call("planet_terrain_sample", canonical.x,
		canonical.y)
	var elevation := float(macro.get("elevation", 0.0))
	var ocean := float(macro.get("ocean", 0.0))
	var lake := float(macro.get("lake", 0.0))
	var water := ocean > 0.50 or lake > 0.52 or elevation < Gen.WATER_Y
	var color: Color
	if water:
		var ocean_depth := clampf((Gen.WATER_Y - elevation) / 360.0, 0.0, 1.0)
		color = Color("287faa").lerp(Color("082b58"), ocean_depth * 0.86)
		if lake > ocean:
			color = color.lerp(Color("2f91ad"), 0.28)
	else:
		var temperature := float(macro.get("temperature", 0.55))
		var moisture := float(macro.get("moisture", 0.50))
		var latitude := float(macro.get("latitude_fraction", 0.0))
		if latitude > 0.91 or temperature < 0.11:
			color = Color("dcebf0")
		elif temperature < 0.26:
			color = Color("788c70")
		elif temperature > 0.58 and moisture < 0.34:
			color = Color("c79a55")
		elif moisture > 0.67 and temperature > 0.48:
			color = Color("195d31")
		elif moisture < 0.46:
			color = Color("7da052")
		else:
			color = Color("3f853e")
		var rocky := smoothstep(700.0, 2500.0, elevation)
		color = color.lerp(Color("76736c"), rocky * 0.88)
		var snow := smoothstep(2800.0, 4300.0, elevation)
		color = color.lerp(Color("e7eef3"), snow)
	return {
		"color": color,
		"elevation": elevation,
		"water": water,
		"road": 0.0,
		"tree_cover": 0.0,
		"biome": -1,
	}


func _sync_seed() -> void:
	if Gen.world_seed == _baked_seed:
		return
	_baked_seed = Gen.world_seed
	_tiles.clear()
	_bake_queue.clear()
	_required_keys.clear()
	# Imported celestial atlases are seed-independent display resources. Keep
	# their resource IDs and sphere meshes stable while only analytic local tiles
	# are invalidated for the new deterministic world seed.


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
	return "%d:%d:%d" % [tier, tile_key.x, tile_key.y]


func _create_tile(cache_key: String, tier: int, tile_key: Vector2i) -> void:
	# RGBA matches the low-alpha satellite overlay, allowing native blend_rect
	# calls with no per-sample format conversion.
	var image := _initial_satellite_tile(tier, tile_key)
	_tiles[cache_key] = {
		"tier": tier,
		"key": tile_key,
		"image": image,
		"texture": ImageTexture.create_from_image(image),
		# The cheap shared-edge overview already supplies the 2x2 stage. Live
		# refinement begins at 4x4 with roads, foliage and local terrain detail.
		"stage": 1,
		"sample_cursor": 0,
		"stage_image": Image.create(LOCAL_PREVIEW_GRIDS[1] + 1,
			LOCAL_PREVIEW_GRIDS[1] + 1, false, Image.FORMAT_RGBA8),
		"stage_ready": false,
		"pending_image": null,
		"touch": _touch_serial,
	}
	_bake_queue.append(cache_key)


## Build a coherent first frame from nine inexpensive whole-planet samples.
## Including tile edges makes adjacent images agree before live local queries
## begin, so a newly opened or quickly panned map never shows flat tile blocks.
func _initial_satellite_tile(tier: int, tile_key: Vector2i) -> Image:
	var tile_world := float(TILE_METERS_PER_PX[tier]) * TILE_PX
	var origin := Vector2(tile_key) * tile_world
	var grid := int(LOCAL_PREVIEW_GRIDS[0])
	var overview := Image.create(grid + 1, grid + 1, false, Image.FORMAT_RGBA8)
	for sample_z in range(grid + 1):
		for sample_x in range(grid + 1):
			var fraction := Vector2(sample_x, sample_z) / float(grid)
			var sample := _planet_overview_sample(origin + fraction * tile_world)
			overview.set_pixel(sample_x, sample_z, sample.color)
	overview.resize(TILE_PX, TILE_PX, Image.INTERPOLATE_LANCZOS)
	_stamp_satellite_detail(overview, Rect2i(0, 0, TILE_PX, TILE_PX),
		Vector2i(tile_key.x * TILE_PX, tile_key.y * TILE_PX))
	return overview


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


func _bake_local_samples(maximum_samples: int) -> void:
	_last_local_texture_uploads = 0
	var deadline := Time.get_ticks_usec() + BAKE_TIME_BUDGET_USEC
	while _last_baked_samples < maximum_samples \
			and Time.get_ticks_usec() < deadline and not _bake_queue.is_empty():
		var cache_key: String = _bake_queue.pop_front()
		if not _tiles.has(cache_key):
			continue
		var tile: Dictionary = _tiles[cache_key]
		# Work in short turns so every visible tile gets its smooth first pass in a
		# few frames. Textures upload only when a complete grid stage resolves.
		var turn_samples := mini(LOCAL_SAMPLES_PER_TILE_TURN,
			maximum_samples - _last_baked_samples)
		for _sample_index in range(turn_samples):
			if _bake_tile_sample(tile):
				break
			_last_baked_samples += 1
			if Time.get_ticks_usec() >= deadline:
				break
		if int(tile.stage) < LOCAL_PREVIEW_GRIDS.size() \
				and not bool(tile.stage_ready):
			_bake_queue.append(cache_key)
	_commit_coherent_local_stage()


## Hold finished tile images until every visible tile at the same refinement
## level is ready. Publishing a stage together removes the temporary checkerboard
## that otherwise appears when adjacent satellite tiles finish on nearby frames.
func _commit_coherent_local_stage() -> void:
	if _required_keys.is_empty():
		return
	var target_stage := LOCAL_PREVIEW_GRIDS.size()
	for cache_key in _required_keys:
		if _tiles.has(cache_key):
			target_stage = mini(target_stage, int(_tiles[cache_key].stage))
	if target_stage >= LOCAL_PREVIEW_GRIDS.size():
		return
	for cache_key in _required_keys:
		if not _tiles.has(cache_key):
			return
		var candidate: Dictionary = _tiles[cache_key]
		if int(candidate.stage) == target_stage \
				and not bool(candidate.stage_ready):
			return
	for cache_key in _required_keys:
		var tile: Dictionary = _tiles[cache_key]
		if int(tile.stage) != target_stage:
			continue
		var pending: Image = tile.pending_image
		if not pending or pending.is_empty():
			continue
		tile.image = pending
		(tile.texture as ImageTexture).update(pending)
		_last_local_texture_uploads += 1
		tile.pending_image = null
		tile.stage_ready = false
		tile.stage = target_stage + 1
		tile.sample_cursor = 0
		if int(tile.stage) < LOCAL_PREVIEW_GRIDS.size():
			var next_grid := int(LOCAL_PREVIEW_GRIDS[int(tile.stage)]) + 1
			tile.stage_image = Image.create(next_grid, next_grid, false,
				Image.FORMAT_RGBA8)
			var queued_key := str(cache_key)
			if not _bake_queue.has(queued_key):
				_bake_queue.append(queued_key)


## Returns true after the final resolution was already complete.
func _bake_tile_sample(tile: Dictionary) -> bool:
	var stage := int(tile.stage)
	if stage >= LOCAL_PREVIEW_GRIDS.size() or bool(tile.stage_ready):
		return true
	var tier: int = tile.tier
	var tile_key: Vector2i = tile.key
	var source_mpp := float(TILE_METERS_PER_PX[tier])
	var tile_world := source_mpp * TILE_PX
	var origin := Vector2(tile_key) * tile_world
	var grid := int(LOCAL_PREVIEW_GRIDS[stage])
	var sample_size := grid + 1
	var cursor := int(tile.sample_cursor)
	var sample_x := cursor % sample_size
	var sample_z := floori(float(cursor) / float(sample_size))
	# Include both tile edges. Adjacent tiles therefore sample the exact same
	# boundary coordinates, eliminating seams after smooth upscaling.
	var fraction := Vector2(sample_x, sample_z) / float(grid)
	var point := origin + fraction * tile_world
	var sample := _map_sample(point, tile_world / float(grid))
	var color: Color = sample.color
	if not bool(sample.get("water", false)):
		var canopy := float(sample.get("tree_cover", 0.0))
		if canopy > 0.08 and _pixel_hash(tile_key.x * grid + sample_x,
				tile_key.y * grid + sample_z) < canopy:
			color = color.lerp(Color("194f25"), canopy * 0.30)
		var road := float(sample.get("road", 0.0))
		if road > 0.12:
			color = color.lerp(Color("9a7342"),
				smoothstep(0.12, 0.8, road) * 0.72)
	var stage_image: Image = tile.stage_image
	stage_image.set_pixel(sample_x, sample_z, color)
	cursor += 1
	if cursor >= sample_size * sample_size:
		# Reconstruct the low-frequency live terrain mask smoothly, then stamp the
		# high-frequency satellite plate exactly once for this refinement stage.
		var refined := stage_image.duplicate()
		refined.resize(TILE_PX, TILE_PX, Image.INTERPOLATE_LANCZOS)
		_stamp_satellite_detail(refined, Rect2i(0, 0, TILE_PX, TILE_PX),
			Vector2i(tile_key.x * TILE_PX, tile_key.y * TILE_PX))
		tile.pending_image = refined
		tile.stage_ready = true
		tile.sample_cursor = 0
	else:
		tile.sample_cursor = cursor
	return false


## Blend a generated, photoreal overhead luminance plate over a live terrain
## color block. The PNG stores black/white detail at low alpha, so Image's native
## C++ blend keeps the procedural biome hue while adding canopy, stone and soil
## structure without another terrain query per output pixel.
func _stamp_satellite_detail(destination: Image, destination_rect: Rect2i,
		world_pixel_origin: Vector2i) -> void:
	if not _satellite_detail_image:
		_satellite_detail_image = SATELLITE_DETAIL_OVERLAY.get_image()
	if not _satellite_detail_image or _satellite_detail_image.is_empty():
		return
	var overlay_size := _satellite_detail_image.get_size()
	if overlay_size.x <= 0 or overlay_size.y <= 0:
		return
	var written_y := 0
	while written_y < destination_rect.size.y:
		var source_y := posmod(world_pixel_origin.y + written_y, overlay_size.y)
		var copy_h := mini(destination_rect.size.y - written_y,
			overlay_size.y - source_y)
		var written_x := 0
		while written_x < destination_rect.size.x:
			var source_x := posmod(world_pixel_origin.x + written_x,
				overlay_size.x)
			var copy_w := mini(destination_rect.size.x - written_x,
				overlay_size.x - source_x)
			destination.blend_rect(_satellite_detail_image,
				Rect2i(source_x, source_y, copy_w, copy_h),
				destination_rect.position + Vector2i(written_x, written_y))
			written_x += copy_w
		written_y += copy_h


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
	if _globe_texture:
		return
	_globe_texture = EARTH_ATLAS
	_globe_stage = 1
	_globe_sample_cursor = 0


func _bake_globe_samples(_maximum_samples: int) -> void:
	_ensure_globe_atlas()
	# Direct imported textures are already complete. This intentionally performs
	# no PlanetTerrain sampling or ImageTexture updates on the render thread.


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
	var equivalent := nearest_equivalent_xz(world_point, _center,
		planet_circumference_m())
	var mpp := _view_span_m / maxf(rect.size.x, 1.0)
	return rect.get_center() + (equivalent - _center) / maxf(mpp, 0.001)


func _draw() -> void:
	if not _open:
		return
	_draw_backdrop()
	var blend := globe_blend()
	if selected_body == CelestialBody.MOON:
		_draw_globe_view()
	else:
		var opacities := transition_opacities(blend)
		if opacities.x > 0.001:
			_draw_local_map(opacities.x)
		if opacities.y > 0.001:
			_draw_globe_view(opacities.y, transition_globe_scale(blend))
	_draw_chrome(blend)


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
		draw_texture_rect(tile.texture, tile_rect, false,
			Color(1.0, 1.0, 1.0, alpha))
	_draw_lat_lon_grid(rect, alpha)
	_draw_local_markers(rect, alpha)
	# Vignette and crisp inner frame make placeholders/refined tiles read as one
	# atlas while the incremental baker catches up.
	draw_rect(rect, _with_alpha(Color(0.02, 0.08, 0.11, 0.18), alpha),
		false, 3.0)
	draw_rect(rect.grow(-2.0),
		_with_alpha(Color(0.58, 0.94, 0.76, 0.42), alpha), false, 1.0)


func _draw_lat_lon_grid(rect: Rect2, alpha := 1.0) -> void:
	var circumference := planet_circumference_m()
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
	for marker in markers_for_body(CelestialBody.EARTH):
		var pos3: Vector3 = marker.position
		var base := world_to_screen(Vector2(pos3.x, pos3.z))
		if not rect.grow(-5.0).has_point(base):
			continue
		var forward := marker_forward(float(marker.yaw))
		var tip := base + forward * 14.0
		var side := forward.orthogonal()
		var polygon := PackedVector2Array([
			tip, base - forward * 7.0 + side * 6.0,
			base - forward * 7.0 - side * 6.0])
		var color := _with_alpha(
			Color("ffe581") if bool(marker.local) else Color("58c8ff"), alpha)
		draw_colored_polygon(polygon, color)
		draw_polyline(polygon + PackedVector2Array([polygon[0]]),
			_with_alpha(Color(0.015, 0.025, 0.03, 0.92), alpha), 2.0)
		_draw_marker_name(base + Vector2(0, -13), str(marker.name), color, alpha)


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
	draw_rect(rect, _with_alpha(Color(0.008, 0.018, 0.045, 0.74), alpha))
	var view_geo := world_xz_to_lon_lat(_center, planet_circumference_m())
	var radius := minf(rect.size.y * 0.405, rect.size.x * 0.31) * globe_scale
	var earth_center := rect.get_center()
	if selected_body == CelestialBody.EARTH:
		earth_center.x -= minf(radius * 0.34, rect.size.x * 0.08)
		_draw_atmosphere(earth_center, radius, alpha)
		_draw_textured_sphere(earth_center, radius, view_geo, false, alpha)
		_draw_globe_markers(earth_center, radius, view_geo, alpha)
		var moon_radius := maxf(radius * 0.17, 26.0)
		var moon_center := earth_center + Vector2(radius * 1.35, -radius * 0.48)
		_draw_moon_sphere(moon_center, moon_radius, view_geo, alpha)
		_moon_globe_rect = Rect2(moon_center - Vector2.ONE * moon_radius * 1.35,
			Vector2.ONE * moon_radius * 2.7)
		draw_string(_font, moon_center + Vector2(-55, moon_radius + 24),
			"MOON  ·  SELECT", HORIZONTAL_ALIGNMENT_CENTER, 110, 12,
			_with_alpha(Color(0.82, 0.88, 1.0, 0.9), alpha))
	else:
		_moon_globe_rect = Rect2()
		var moon_center := rect.get_center()
		_draw_moon_sphere(moon_center, radius, view_geo, alpha)
		_draw_moon_markers(moon_center, radius, view_geo, alpha)
		var earth_small_center := rect.position + Vector2(90, rect.size.y - 78)
		_draw_atmosphere(earth_small_center, 48.0, alpha)
		_draw_textured_sphere(earth_small_center, 48.0, view_geo, false, alpha)
		draw_string(_font, rect.get_center() + Vector2(-180, radius + 36),
			"LUNAR SURFACE  ·  DESTINATION VIEW", HORIZONTAL_ALIGNMENT_CENTER,
			360, 15, _with_alpha(Color("dbe6ff"), alpha))
		draw_string(_font, rect.get_center() + Vector2(-250, radius + 61),
			"Local moon cartography unlocks with the lunar mission",
			HORIZONTAL_ALIGNMENT_CENTER, 500, 12,
			_with_alpha(Color(0.65, 0.72, 0.84, 0.86), alpha))
	draw_rect(rect, _with_alpha(Color(0.58, 0.81, 1.0, 0.35), alpha),
		false, 2.0)


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


## The 4K Moon is a direct imported resource shared by every atlas instance.
## No image allocation, crater stamping, or per-frame refinement occurs here.
func _ensure_moon_atlas() -> void:
	if _moon_texture:
		return
	_moon_texture = MOON_ATLAS


func _draw_moon_sphere(center: Vector2, radius: float,
		view_lon_lat: Vector2, alpha := 1.0) -> void:
	_ensure_moon_atlas()
	draw_circle(center, radius + maxf(3.0, radius * 0.018),
		_with_alpha(Color(0.55, 0.64, 0.77, 0.16), alpha))
	var mesh := _sphere_mesh_for_view(view_lon_lat, true)
	var transform := Transform2D(Vector2(radius, 0.0), Vector2(0.0, radius),
		center)
	draw_mesh(mesh, _moon_texture, transform, Color(1.0, 1.0, 1.0, alpha))
	# The imported albedo already contains crater and maria detail, so the Moon is
	# one texture draw plus the inexpensive limb accents.
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
		var position: Vector3 = marker.position
		var projected := moon_marker_projection(position, float(marker.yaw),
			center, radius, view_lon_lat)
		if not bool(projected.visible):
			continue
		var marker_position: Vector2 = projected.position
		var direction: Vector2 = projected.direction
		var color := _with_alpha(
			Color("ffe581") if bool(marker.local) else Color("58c8ff"), alpha)
		draw_circle(marker_position, 5.5,
			_with_alpha(Color(0.01, 0.02, 0.04, 0.9), alpha))
		draw_circle(marker_position, 3.7, color)
		draw_line(marker_position, marker_position + direction * 11.0,
			color, 2.2, true)
		_draw_marker_name(marker_position + Vector2(0, -8), str(marker.name),
			color, alpha)


func _draw_chrome(blend: float) -> void:
	var rect := map_rect()
	draw_rect(Rect2(0, 0, size.x, HEADER_H), Color(0.018, 0.045, 0.064, 0.96))
	draw_line(Vector2(0, HEADER_H - 1), Vector2(size.x, HEADER_H - 1),
		Color(0.36, 0.86, 0.66, 0.58), 2.0)
	draw_string(_font, Vector2(96, 31), "TROOP PLANETARY ATLAS",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 22, Color("d9ffdf"))
	draw_string(_font, Vector2(MAP_MARGIN, 54),
		"LIVE TERRAIN  •  SPHERICAL WORLD  •  SEAMLESS NAVIGATION",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.47, 0.78, 0.67, 0.92))
	var button_y := 18.0
	_earth_button_rect = Rect2(size.x - 348, button_y, 94, 38)
	_moon_button_rect = Rect2(size.x - 246, button_y, 92, 38)
	_home_button_rect = Rect2(size.x - 146, button_y, 54, 38)
	_close_button_rect = Rect2(size.x - 84, button_y, 60, 38)
	_draw_button(_earth_button_rect, "EARTH",
		selected_body == CelestialBody.EARTH)
	_draw_button(_moon_button_rect, "MOON",
		selected_body == CelestialBody.MOON)
	_draw_button(_home_button_rect, "⌖", false)
	_draw_button(_close_button_rect, "X", false)
	draw_rect(Rect2(0, size.y - FOOTER_H, size.x, FOOTER_H),
		Color(0.018, 0.045, 0.064, 0.97))
	draw_line(Vector2(0, size.y - FOOTER_H),
		Vector2(size.x, size.y - FOOTER_H), Color(0.36, 0.86, 0.66, 0.4), 1.0)
	var footer := "DRAG / WASD PAN    •    WHEEL ZOOM    •    HOME RECENTER    •    X OR ESC CLOSE"
	draw_string(_font, Vector2(MAP_MARGIN, size.y - 18), footer,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.79, 0.91, 0.84, 0.9))
	var right_status := ""
	if selected_body == CelestialBody.MOON:
		right_status = "MOON  •  1.62 m/s²  •  TRAVEL TARGET"
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
	var fill := Color("18634f") if active else Color(0.035, 0.10, 0.135, 0.95)
	if hovered:
		fill = fill.lightened(0.10)
	draw_style_box(_rounded_box(fill,
		Color("73e0a6") if active else Color(0.32, 0.58, 0.62, 0.75), 1, 8), rect)
	draw_string(_font, rect.position + Vector2(0, 25), text_value,
		HORIZONTAL_ALIGNMENT_CENTER, rect.size.x, 12,
		Color.WHITE if active or hovered else Color(0.72, 0.84, 0.86))


func _draw_scale_bar(rect: Rect2) -> void:
	if selected_body != CelestialBody.EARTH or globe_blend() >= 0.52:
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
		"atlas_stage": _globe_stage,
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
