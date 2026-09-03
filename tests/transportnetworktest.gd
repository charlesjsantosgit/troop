extends SceneTree
## Focused deterministic validation for curved-road engineering structures.
## Run with:
##   godot --headless --path . --script res://tests/transportnetworktest.gd

var passed := 0
var total := 0
const GenScript = preload("res://scripts/gen.gd")
const RoadBridgeScript = preload("res://scripts/road_bridge.gd")
const FreewayTunnelScript = preload("res://scripts/freeway_tunnel.gd")
# A real seed-1337 lake-edge crossing, not a synthetic road/terrain override.
# The globe grid below is hundreds of kilometres apart and cannot reliably
# find a 180 m water crossing after removal of the old fine-noise cliffs.
const WATER_BRIDGE_PROBE := Vector2(-125290.5, -3266438.0)
var generator
var highway_candidates := 0
var maximum_highway_mountain := 0.0
var maximum_highway_elevation := -INF
var minimum_highway_grade := INF
var maximum_highway_ridge := -INF
var dry_mountain_slots := 0
var grade_safe_mountain_slots := 0
var tunnel_shape_slots := 0
var portal_land_slots := 0


func _initialize() -> void:
	call_deferred("_run")


func _check(ok: bool, label: String, info := "") -> void:
	total += 1
	if ok:
		passed += 1
		print("  [ok] " + label)
	else:
		print("  [FAIL] " + label + ((" :: " + info) if not info.is_empty()
			else ""))


func _candidate_feature(probe: Vector2) -> Dictionary:
	var road: Dictionary = generator._planet_roads.surface_sample(probe)
	var tangent: Vector2 = road.get("tangent", Vector2.RIGHT)
	var coordinate := float(road.get("bridge_coordinate", 0.0))
	var center: Vector2 = road.get("center_point", probe) + tangent \
		* (coordinate - float(road.get("route_coordinate", coordinate)))
	for _projection in range(3):
		road = generator._planet_roads.surface_sample(center)
		tangent = road.get("tangent", tangent).normalized()
		coordinate = float(road.get("bridge_coordinate", coordinate))
		center = road.get("center_point", center) + tangent \
			* (coordinate - float(road.get("route_coordinate", coordinate)))
	if not bool(road.get("bridge_candidate", false)):
		return {}
	if str(road.get("tier", "")) == "highway":
		highway_candidates += 1
		var exact_center: Vector2 = road.get("center_point", center)
		var macro: Dictionary = generator.planet_terrain_sample(
			exact_center.x, exact_center.y)
		var extent: float = generator.FREEWAY_TUNNEL_LENGTH * 0.5 \
			+ generator.FREEWAY_TUNNEL_APPROACH
		var a_macro: Dictionary = generator.planet_terrain_sample(
			exact_center.x - tangent.x * extent,
			exact_center.y - tangent.y * extent)
		var b_macro: Dictionary = generator.planet_terrain_sample(
			exact_center.x + tangent.x * extent,
			exact_center.y + tangent.y * extent)
		var portal_a := float(a_macro.elevation)
		var portal_b := float(b_macro.elevation)
		var dry_mountain: bool = float(macro.land) > 0.62 \
			and float(macro.ocean) < 0.26 and float(macro.lake) < 0.28 \
			and float(macro.mountain) > 0.42 \
			and float(macro.elevation) > generator.WATER_Y + 120.0
		var measured_grade: float = absf(portal_b - portal_a) / (extent * 2.0)
		var measured_ridge: float = float(macro.elevation) \
			- (portal_a + portal_b) * 0.5
		if dry_mountain:
			dry_mountain_slots += 1
			if measured_grade <= generator.ROAD_MAX_GRADE * 1.25:
				grade_safe_mountain_slots += 1
				if float(a_macro.land) > 0.54 and float(b_macro.land) > 0.54:
					portal_land_slots += 1
				if measured_ridge > 5.0 or float(macro.mountain) > 0.62:
					tunnel_shape_slots += 1
		maximum_highway_mountain = maxf(maximum_highway_mountain,
			float(macro.mountain))
		maximum_highway_elevation = maxf(maximum_highway_elevation,
			float(macro.elevation))
		minimum_highway_grade = minf(minimum_highway_grade,
			measured_grade)
		maximum_highway_ridge = maxf(maximum_highway_ridge,
			measured_ridge)
	return generator._transport_feature_for_road(road)


func _layout_contains(feature: Dictionary) -> bool:
	var pos: Vector3 = feature.pos
	var cx := floori(pos.x / generator.CHUNK)
	var cz := floori(pos.z / generator.CHUNK)
	var key := "freeway_tunnels" if str(feature.kind) == "tunnel" \
		else "road_bridges"
	var matches := 0
	for dz in range(-1, 2):
		for dx in range(-1, 2):
			var layout: Dictionary = generator.transport_feature_chunk_layout(
				cx + dx, cz + dz)
			for streamed_value in layout.get(key, []):
				var streamed: Dictionary = streamed_value
				if str(streamed.get("id", "")) == str(feature.id):
					if dx != 0 or dz != 0:
						return false
					matches += 1
	return matches == 1


func _bridge_spans_real_water(feature: Dictionary) -> bool:
	var position: Vector3 = feature.pos
	var center := Vector2(position.x, position.z)
	var tangent: Vector2 = feature.tangent
	var half_length := float(feature.length) * 0.5
	var bed: Dictionary = generator.planet_terrain_sample(center.x, center.y)
	if float(bed.elevation) >= generator.WATER_Y \
			or float(feature.deck_elevation) < generator.WATER_Y + 1.0:
		return false
	for sign_value in [-1.0, 1.0]:
		var bank: Vector2 = center + tangent * half_length * sign_value
		var macro: Dictionary = generator.planet_terrain_sample(bank.x, bank.y)
		if float(macro.land) <= 0.58 or float(macro.ocean) >= 0.34 \
				or float(macro.lake) >= 0.34 \
				or float(macro.elevation) <= generator.WATER_Y + 0.28:
			return false
		# The actual graded road must join the physical deck at both banks.
		if absf(generator.height(bank.x, bank.y) - position.y) > 0.10:
			return false
	return true


func _run() -> void:
	print("TRANSPORTNETWORKTEST begin")
	generator = GenScript.new()
	root.add_child(generator)
	generator.debug_world = false
	generator.setup(1337)
	var bridge: Dictionary = _candidate_feature(WATER_BRIDGE_PROBE)
	if str(bridge.get("kind", "")) != "bridge":
		bridge = {}
	var tunnel: Dictionary = {}
	var seen: Dictionary = {}
	# Pangaea occupies the central chart. Sparse globe-scale probes select stable
	# route slots; each candidate itself is projected exactly before evaluation.
	for latitude_index in range(19):
		var latitude := lerpf(-0.86, 0.86, float(latitude_index) / 18.0)
		for longitude_index in range(35):
			var longitude := lerpf(-1.62, 1.62,
				float(longitude_index) / 34.0)
			var probe := Vector2(longitude * generator.PLANET_RADIUS,
				latitude * generator.PLANET_RADIUS)
			var feature := _candidate_feature(probe)
			if feature.is_empty() or seen.has(str(feature.id)):
				continue
			seen[str(feature.id)] = true
			if str(feature.kind) == "bridge" and bridge.is_empty():
				bridge = feature
			elif str(feature.kind) == "tunnel" and tunnel.is_empty():
				tunnel = feature
			if not bridge.is_empty() and not tunnel.is_empty():
				break
		if not bridge.is_empty() and not tunnel.is_empty():
			break
	_check(not bridge.is_empty(),
		"organic arterials deterministically bridge water or ravines",
		"candidates=%d" % seen.size())
	_check(not tunnel.is_empty(),
		"highways deterministically bore through dry mountain ranges",
		("features=%d highway_slots=%d max_mountain=%.3f max_elevation=%.1f " \
		+ "min_grade=%.3f max_ridge=%.1f dry=%d grade=%d portals=%d shape=%d") % [
			seen.size(), highway_candidates,
			maximum_highway_mountain, maximum_highway_elevation,
			minimum_highway_grade, maximum_highway_ridge, dry_mountain_slots,
			grade_safe_mountain_slots, portal_land_slots, tunnel_shape_slots])
	if not bridge.is_empty():
		_check(_bridge_spans_real_water(bridge),
			"the fixed crossing has submerged ground, dry banks and connected road approaches")
		generator.setup(1337)
		_check(str(_candidate_feature(WATER_BRIDGE_PROBE)) == str(bridge),
			"bridge identity, position and dimensions repeat after a fresh seeded setup")
		_check(_layout_contains(bridge),
			"bridge materializes exactly once in its owning streamed chunk")
		var bridge_node = RoadBridgeScript.new()
		bridge_node.configure(bridge)
		root.add_child(bridge_node)
		await process_frame
		_check(bridge_node.get_node_or_null("BatchedBridgeDeck") != null \
				and bridge_node.build_collisions().size() == 1,
			"bridge supplies a batched deck and driveable physical collision")
		await physics_frame
		await physics_frame
		var deck_collision: StaticBody3D = bridge_node.get_node("RoadBridgeCollision")
		var deck_supported := true
		for along in [-0.40, 0.0, 0.40]:
			var deck_point: Vector3 = bridge_node.to_global(
				Vector3(0.0, 0.0, float(bridge.length) * along))
			var query := PhysicsRayQueryParameters3D.create(
				deck_point + Vector3.UP * 2.0, deck_point - Vector3.UP * 2.0, 1)
			var hit := bridge_node.get_world_3d().direct_space_state.intersect_ray(query)
			deck_supported = deck_supported and not hit.is_empty() \
				and hit.get("collider") == deck_collision \
				and absf((hit.get("position", Vector3.ZERO) as Vector3).y - deck_point.y) < 0.02
		_check(deck_supported,
			"the physical deck supports the roadway at both ends and above the water")
		bridge_node.queue_free()
	if not tunnel.is_empty():
		_check(_layout_contains(tunnel),
			"tunnel materializes exactly once in its owning streamed chunk")
		var tunnel_node = FreewayTunnelScript.new()
		tunnel_node.configure(tunnel)
		root.add_child(tunnel_node)
		await process_frame
		_check(tunnel_node.get_node_or_null("BatchedTunnelShell") != null \
				and tunnel_node.light_count() == 6 \
				and tunnel_node.build_collisions().size() == 1,
			"mountain tunnel has an arched shell, six warm lamps and collision")
		tunnel_node.queue_free()
	print("TRANSPORTNETWORKTEST %d/%d %s" % [passed, total,
		"PASS" if passed == total else "FAIL"])
	quit(0 if passed == total else 1)
