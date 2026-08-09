extends SceneTree
## Isolated analytic-road regression. Run with:
##   godot --headless --path . --script res://tests/roadnetworktest.gd

var failures := 0
var total := 0


func check(label: String, ok: bool, detail := "") -> void:
	total += 1
	if ok:
		print("  [ok] " + label)
	else:
		failures += 1
		print("  [FAIL] " + label + (" :: " + detail if detail != "" else ""))


func _initialize() -> void:
	print("ROADNETWORKTEST begin")
	var roads := PlanetRoadNetwork.new()
	roads.setup(88421)
	# Four-metre alignment remains exactly representable when added to an
	# Earth-circumference float32 Vector2 chart image.
	var probe := Vector2(12_344.0, -67_888.0)
	var sample: Dictionary = roads.surface_sample(probe)
	var required_fields := PackedStringArray([
		"tier", "route_id", "line_index", "axis", "center_point",
		"tangent", "route_coordinate", "along", "distance", "half_width",
		"grade", "curve_offset", "bridge_candidate",
		"bridge_candidate_score", "bridge_slot", "bridge_coordinate",
		"bridge_id",
		"intersection_score", "intersection_id", "elevation",
	])
	var fields_present := true
	for field in required_fields:
		fields_present = fields_present and sample.has(field)
	var tangent: Vector2 = sample.tangent
	var center: Vector2 = sample.center_point
	check("surface sample preserves compatibility fields and route metadata",
		fields_present and absf(tangent.length() - 1.0) < 0.0001
		and center.distance_to(probe) <= float(sample.distance) + 0.02,
		"keys=%s tangent=%.5f projection_error=%.4f" % [sample.keys(),
			tangent.length(), center.distance_to(probe) - float(sample.distance)])

	var same_seed := PlanetRoadNetwork.new()
	same_seed.setup(88421)
	var repeated: Dictionary = same_seed.surface_sample(probe)
	var other_seed := PlanetRoadNetwork.new()
	other_seed.setup(88422)
	var changed: Dictionary = other_seed.surface_sample(probe)
	check("seeded curves and route metadata repeat exactly",
		str(sample) == str(repeated), str(sample) + " != " + str(repeated))
	check("world seed changes the organic route shape without changing API",
		(sample.center_point as Vector2).distance_to(changed.center_point) > 0.5
		and str(sample.tier) == str(changed.tier),
		"center_delta=%.3f" % (sample.center_point as Vector2).distance_to(
			changed.center_point))
	check("bridge slots expose an exact deterministic along-route coordinate",
		is_equal_approx(float(sample.bridge_coordinate),
			float(repeated.bridge_coordinate))
		and bool(sample.bridge_candidate) \
			== (float(sample.bridge_candidate_score) > 0.0)
		and (str(sample.bridge_id) != "") == bool(sample.bridge_candidate),
		"candidate=%s score=%.3f coordinate=%.2f" % [
			str(sample.bridge_candidate), sample.bridge_candidate_score,
			sample.bridge_coordinate])
	var exact_junction: Vector2 = roads._curve_point(0, 0.0, 0.0)
	var junction_sample: Dictionary = roads.surface_sample(exact_junction)
	check("shared domain warp produces stable exact route intersections",
		float(junction_sample.intersection_score) > 0.98
		and str(junction_sample.intersection_id) != "",
		"score=%.4f id=%s" % [junction_sample.intersection_score,
			junction_sample.intersection_id])

	var circumference: float = PlanetTerrain.CIRCUMFERENCE
	var seam: Dictionary = roads.surface_sample(probe
		+ Vector2(circumference, 0.0))
	check("road geometry and stable IDs join exactly at longitude seam",
		str(sample.route_id) == str(seam.route_id)
		and absf(float(sample.distance) - float(seam.distance)) < 0.0001
		and (sample.center_point as Vector2).distance_to(seam.center_point) < 0.001
		and (sample.tangent as Vector2).dot(seam.tangent) > 0.999999,
		"id=%s/%s distance=%.6f/%.6f center=%s/%s tangent=%s/%s" % [
			sample.route_id, seam.route_id, sample.distance, seam.distance,
			str(sample.center_point), str(seam.center_point), str(sample.tangent),
			str(seam.tangent)])
	var beyond_north := Vector2(54_321.0,
		PlanetTerrain.QUARTER_CIRCUMFERENCE + 1250.0)
	var reflected_north := Vector2(54_321.0 + PlanetTerrain.HALF_CIRCUMFERENCE,
		PlanetTerrain.QUARTER_CIRCUMFERENCE - 1250.0)
	var pole_a: Dictionary = roads.surface_sample(beyond_north)
	var pole_b: Dictionary = roads.surface_sample(reflected_north)
	check("road geometry uses the same exact pole reflection as terrain",
		str(pole_a.route_id) == str(pole_b.route_id)
		and absf(float(pole_a.distance) - float(pole_b.distance)) < 0.0001
		and (pole_a.center_point as Vector2).distance_to(pole_b.center_point) < 0.001,
		"id=%s/%s distance=%.6f/%.6f" % [pole_a.route_id,
			pole_b.route_id, pole_a.distance, pole_b.distance])
	var profile_here: float = roads.profile_elevation(probe)
	var profile_seam: float = roads.profile_elevation(probe
		+ Vector2(circumference, 0.0))
	var profile_pole_a: float = roads.profile_elevation(beyond_north)
	var profile_pole_b: float = roads.profile_elevation(reflected_north)
	check("spherical road elevation profile also wraps at seam and poles",
		absf(profile_here - profile_seam) < 0.001
		and absf(profile_pole_a - profile_pole_b) < 0.001,
		"seam=%.6f pole=%.6f" % [absf(profile_here - profile_seam),
			absf(profile_pole_a - profile_pole_b)])

	var local_rect := Rect2(Vector2(-2400.0, -2400.0),
		Vector2(4800.0, 4800.0))
	var segments: Array = roads.segments_in_rect(local_rect, 128)
	var fields_ok := not segments.is_empty() and segments.size() <= 128
	var family_tangents: Dictionary = {}
	var curved_route := false
	var non_orthogonal_pair := false
	var first_a := Vector2.ZERO
	var first_b := Vector2.ZERO
	var got_a := false
	var got_b := false
	for segment_value in segments:
		var segment: Dictionary = segment_value
		fields_ok = fields_ok and segment.has("id") and segment.has("tier") \
			and segment.has("half_width") and segment.has("a") \
			and segment.has("b") and segment.has("tangent") \
			and segment.has("route_coordinate") \
			and segment.has("bridge_candidate_score") \
			and segment.has("bridge_coordinate")
		var route_id := str(segment.id)
		var route_tangent: Vector2 = segment.tangent
		if family_tangents.has(route_id):
			var prior: Vector2 = family_tangents[route_id]
			curved_route = curved_route or absf(prior.cross(route_tangent)) > 0.002
		else:
			family_tangents[route_id] = route_tangent
		if str(segment.family) == "sweeping_meridian" and not got_a:
			first_a = route_tangent
			got_a = true
		elif str(segment.family) == "cross_country" and not got_b:
			first_b = route_tangent
			got_b = true
		if got_a and got_b:
			var family_dot := absf(first_a.dot(first_b))
			non_orthogonal_pair = family_dot > 0.12 and family_dot < 0.82
	check("bounded segment API exposes curved route chords and metadata",
		fields_ok and curved_route,
		"segments=%d curved=%s" % [segments.size(), str(curved_route)])
	check("arterial families meet at useful non-orthogonal headings",
		non_orthogonal_pair,
		"dot=%.3f" % absf(first_a.dot(first_b)))

	var huge_rect := Rect2(Vector2(-circumference * 0.5,
		-PlanetTerrain.QUARTER_CIRCUMFERENCE),
		Vector2(circumference, PlanetTerrain.HALF_CIRCUMFERENCE))
	var bounded_a: Array = roads.segments_in_rect(huge_rect, 17)
	var bounded_b: Array = roads.segments_in_rect(huge_rect, 17)
	check("planet-scale segment queries remain deterministic and hard-bounded",
		bounded_a.size() <= 17 and not bounded_a.is_empty()
		and str(bounded_a) == str(bounded_b),
		"returned=%d" % bounded_a.size())

	print("ROADNETWORKTEST %d/%d %s" % [total - failures, total,
		"PASS" if failures == 0 else "FAIL"])
	quit(failures)
