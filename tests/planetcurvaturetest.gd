extends SceneTree
## Focused visual-contract regression for the continuous Earth/Moon voyage.
## This gate deliberately inspects authored geometry and every 30/60 FPS frame;
## state-machine timing alone cannot catch a flat terrain-to-globe pop or an
## alpha-dissolved Moon.
##
## Run with:
##   godot --headless --path . --script res://tests/planetcurvaturetest.gd

var passed := 0
var total := 0

const EXPECTED_EARTH_DIAMETER_KM := 24_000.0
const EXPECTED_EARTH_RADIUS_KM := 12_000.0
const EXPECTED_MOON_DIAMETER_KM := 3_474.8
const EXPECTED_MOON_RADIUS_KM := 1_737.4
const MIN_GLOBE_RADIAL_SEGMENTS := 192
const MIN_GLOBE_RINGS := 96
const MIN_ATLAS_WIDTH := 4096
const MIN_ATLAS_HEIGHT := 2048
const GEOMETRY_EPSILON := 0.0001


func _initialize() -> void:
	call_deferred("_run")


func _check(ok: bool, label: String, detail := "") -> void:
	total += 1
	if ok:
		passed += 1
		print("  [ok] " + label)
	else:
		print("  [FAIL] " + label + ((" :: " + detail)
			if not detail.is_empty() else ""))


func _sphere_surface_y(x: float, z: float, radius_m: float) -> float:
	var radial_squared := x * x + z * z
	if radial_squared >= radius_m * radius_m:
		return -radius_m
	return sqrt(radius_m * radius_m - radial_squared) - radius_m


func _mesh_arrays(instance: MeshInstance3D) -> Array:
	if not instance or not instance.mesh or instance.mesh.get_surface_count() < 1:
		return []
	return instance.mesh.surface_get_arrays(0)


func _call_surface_sampler(target: Object, method_names: Array[StringName],
		flat_position: Vector3) -> Dictionary:
	for method_name in method_names:
		if target.has_method(method_name):
			var sampled: Variant = target.call(method_name, flat_position)
			if sampled is Vector3:
				return {"found": true, "method": method_name, "point": sampled}
	return {"found": false, "method": &"", "point": Vector3.INF}


func _relative_geometry_step(position: Vector3, scale_value: float,
		previous_position: Vector3, previous_scale: float) -> float:
	var position_step := position.distance_to(previous_position) / maxf(
		maxf(position.length(), previous_position.length()), 1.0)
	var scale_step := absf(scale_value - previous_scale) / maxf(
		maxf(absf(scale_value), absf(previous_scale)), 1.0)
	return maxf(position_step, scale_step)


func _set_rocket_sample(rocket: Variant, rocket_script: GDScript,
		elapsed: float, is_outbound: bool) -> void:
	var duration := float(rocket_script.OUTBOUND_DURATION_SECONDS) \
		if is_outbound else float(rocket_script.RETURN_DURATION_SECONDS)
	rocket.outbound = is_outbound
	rocket.voyage_elapsed = elapsed
	rocket.state = rocket_script.state_for_elapsed(is_outbound, elapsed)
	rocket.global_transform = rocket._flight_transform(elapsed / duration)
	rocket.voyage_visuals.update_voyage(
		elapsed / duration, rocket.state, is_outbound)


func _moon_proxy_sweep(rocket: Variant, rocket_script: GDScript,
		fps: int, start_seconds: float, end_seconds: float,
		is_outbound: bool) -> Dictionary:
	var every_frame_opaque := true
	var continuous_geometry := true
	var max_step := 0.0
	var max_step_elapsed := start_seconds
	var first_nonopaque_elapsed := -1.0
	var previous_position := Vector3.ZERO
	var previous_scale := 0.0
	var first := true
	var frame_count := roundi((end_seconds - start_seconds) * fps)
	for frame in range(frame_count + 1):
		var elapsed := start_seconds + float(frame) / float(fps)
		_set_rocket_sample(rocket, rocket_script, elapsed, is_outbound)
		var moon: MeshInstance3D = rocket.voyage_visuals.moon_visual
		var opacity := 1.0 - float(moon.transparency)
		every_frame_opaque = every_frame_opaque and moon.visible \
			and absf(opacity - 1.0) <= GEOMETRY_EPSILON
		if first_nonopaque_elapsed < 0.0 \
				and (not moon.visible or absf(opacity - 1.0) > GEOMETRY_EPSILON):
			first_nonopaque_elapsed = elapsed
		if not first:
			var step := _relative_geometry_step(moon.position, moon.scale.x,
				previous_position, previous_scale)
			if step > max_step:
				max_step = step
				max_step_elapsed = elapsed
			# Thirty FPS permits twice the per-frame motion of sixty FPS. Both
			# bounds are comfortably above ordinary camera motion but below a pop.
			continuous_geometry = continuous_geometry \
				and step < (0.075 if fps == 30 else 0.04)
		previous_position = moon.position
		previous_scale = moon.scale.x
		first = false
	return {
		"opaque": every_frame_opaque,
		"continuous": continuous_geometry,
		"max_step": max_step,
		"max_step_elapsed": max_step_elapsed,
		"first_nonopaque_elapsed": first_nonopaque_elapsed,
	}


func _landing_motion_sweep(rocket: Variant, rocket_script: GDScript,
		fps: int, flip_start: float, descent_start: float) -> Dictionary:
	var landing_up: Vector3 = rocket.moon_landing_transform.basis.y.normalized()
	var first_pose: Transform3D = rocket._flight_transform(
		flip_start / float(rocket_script.OUTBOUND_DURATION_SECONDS))
	var midpoint_pose: Transform3D = rocket._flight_transform(
		((flip_start + descent_start) * 0.5) \
			/ float(rocket_script.OUTBOUND_DURATION_SECONDS))
	var previous_pose := first_pose
	var max_rotation_step_degrees := 0.0
	var max_position_step := 0.0
	var continuous := true
	var frame_count := roundi((descent_start - flip_start) * fps)
	for frame in range(1, frame_count + 1):
		var elapsed := flip_start + float(frame) / float(fps)
		var pose: Transform3D = rocket._flight_transform(
			elapsed / float(rocket_script.OUTBOUND_DURATION_SECONDS))
		var rotation_step := rad_to_deg(previous_pose.basis \
			.get_rotation_quaternion().angle_to(
				pose.basis.get_rotation_quaternion()))
		var position_step := previous_pose.origin.distance_to(pose.origin)
		max_rotation_step_degrees = maxf(max_rotation_step_degrees,
			rotation_step)
		max_position_step = maxf(max_position_step, position_step)
		continuous = continuous \
			and rotation_step < (5.0 if fps == 30 else 2.6) \
			and position_step < (180.0 if fps == 30 else 95.0)
		previous_pose = pose
	var final_pose := previous_pose
	var visible_flip_degrees := rad_to_deg(first_pose.basis \
		.get_rotation_quaternion().angle_to(
			final_pose.basis.get_rotation_quaternion()))
	var upright_dot := final_pose.basis.y.normalized().dot(landing_up)
	var descent_monotonic := true
	var descent_upright := true
	var previous_clearance := INF
	var duration := float(rocket_script.OUTBOUND_DURATION_SECONDS)
	var descent_frames := roundi((duration - descent_start) * fps)
	for frame in range(descent_frames + 1):
		var elapsed := descent_start + float(frame) / float(fps)
		var pose: Transform3D = rocket._flight_transform(elapsed / duration)
		var clearance: float = (pose.origin \
			- rocket.moon_landing_transform.origin).dot(landing_up)
		if frame > 0:
			descent_monotonic = descent_monotonic \
				and clearance <= previous_clearance + 0.001
		descent_upright = descent_upright \
			and pose.basis.y.normalized().dot(landing_up) > 0.999
		previous_clearance = clearance
	return {
		"continuous": continuous,
		"visible_flip_degrees": visible_flip_degrees,
		"initial_up_dot": first_pose.basis.y.normalized().dot(landing_up),
		"midpoint_up_dot": midpoint_pose.basis.y.normalized().dot(landing_up),
		"upright_dot": upright_dot,
		"descent_monotonic": descent_monotonic,
		"descent_upright": descent_upright,
		"max_rotation_step_degrees": max_rotation_step_degrees,
		"max_position_step": max_position_step,
	}


func _run() -> void:
	print("PLANET CURVATURE TEST")
	var visuals_script := load("res://scripts/space_voyage_visuals.gd") \
		as GDScript
	var rocket_script := load("res://scripts/lunar_rocket.gd") as GDScript
	var moon_script := load("res://scripts/moon_world.gd") as GDScript
	if not visuals_script or not rocket_script or not moon_script:
		_check(false, "voyage, rocket, and Moon scripts load")
		print("PLANETCURVATURETEST %d/%d FAIL" % [passed, total])
		quit(1)
		return

	var stage := Node3D.new()
	stage.name = "PlanetCurvatureStage"
	root.add_child(stage)
	var moon: Variant = moon_script.new()
	moon.name = "CurvatureMoon"
	moon.moon_seed = 904_1969
	stage.add_child(moon)
	var rocket: Variant = rocket_script.new()
	stage.add_child(rocket)
	await process_frame
	rocket.set_physics_process(false)
	var earth_pose := Transform3D(Basis.IDENTITY, Vector3(0.0, 5.0, 0.0))
	var moon_pose := Transform3D(Basis(Vector3.UP, PI),
		Vector3(-54.0, 48_004.4, 42.0))
	var ocean_pose := Transform3D(Basis(Vector3.UP, 0.72),
		Vector3(840.0, 0.6, -620.0))
	rocket.configure_route(earth_pose, moon_pose, ocean_pose)
	rocket.voyage_visuals.set_cinematic_terrain_enabled(true)

	var constants: Dictionary = visuals_script.get_script_constant_map()
	var earth_diameter_km := float(constants.get(
		"EARTH_AUTHORED_DIAMETER_KM", -1.0))
	var earth_radius_km := float(constants.get(
		"EARTH_AUTHORED_RADIUS_KM", -1.0))
	var moon_diameter_km := float(constants.get(
		"MOON_AUTHORED_DIAMETER_KM", -1.0))
	var moon_radius_km := float(constants.get(
		"MOON_AUTHORED_RADIUS_KM", -1.0))
	_check(is_equal_approx(earth_diameter_km, EXPECTED_EARTH_DIAMETER_KM) \
			and is_equal_approx(earth_radius_km, EXPECTED_EARTH_RADIUS_KM) \
			and is_equal_approx(earth_radius_km * 2.0, earth_diameter_km),
		"cinematic Earth remains exactly 24,000 km across",
		"diameter_km=%.3f radius_km=%.3f" % [
			earth_diameter_km, earth_radius_km])
	_check(is_equal_approx(moon_diameter_km, EXPECTED_MOON_DIAMETER_KM) \
			and is_equal_approx(moon_radius_km, EXPECTED_MOON_RADIUS_KM) \
			and is_equal_approx(moon_radius_km * 2.0, moon_diameter_km),
		"cinematic Moon retains its exact 3,474.8 km astronomical diameter",
		"diameter_km=%.3f radius_km=%.3f" % [
			moon_diameter_km, moon_radius_km])

	# The public CPU samplers mirror the exact render deformation. That gives
	# deterministic coverage of the shader/cap tangent without depending on a
	# particular mesh partition or LOD implementation.
	_set_rocket_sample(rocket, rocket_script, 0.0, true)
	var earth_sampler_names: Array[StringName] = [
		&"cinematic_earth_surface_point",
		&"earth_cinematic_surface_point",
		&"earth_surface_point",
	]
	var earth_center_sample := _call_surface_sampler(
		rocket.voyage_visuals, earth_sampler_names, earth_pose.origin)
	var earth_radial_position := earth_pose.origin + Vector3(100_000.0, 0.0, 0.0)
	var earth_edge_sample := _call_surface_sampler(
		rocket.voyage_visuals, earth_sampler_names, earth_radial_position)
	var expected_earth_sag_m := -_sphere_surface_y(
		100_000.0, 0.0, EXPECTED_EARTH_RADIUS_KM * 1000.0)
	var sampled_earth_sag_m := INF
	if bool(earth_center_sample.found) and bool(earth_edge_sample.found):
		sampled_earth_sag_m = (earth_center_sample.point as Vector3).y \
			- (earth_edge_sample.point as Vector3).y
	_check(bool(earth_center_sample.found) and bool(earth_edge_sample.found) \
			and absf(sampled_earth_sag_m - expected_earth_sag_m) <= 2.0 \
			and (earth_center_sample.point as Vector3) \
				.distance_to(earth_pose.origin) <= 0.01,
		"Earth terrain sampler is tangent to the same 12,000 km-radius sphere",
		"method=%s expected_100km_sag=%.3f sampled=%.3f" % [
			str(earth_center_sample.method), expected_earth_sag_m,
			sampled_earth_sag_m])
	var moon_sampler_names: Array[StringName] = [
		&"cinematic_surface_point",
		&"cinematic_moon_surface_point",
		&"moon_surface_point",
	]
	var landing_xz: Vector2 = moon_script.LANDING_XZ
	var moon_center_flat := Vector3(landing_xz.x, 0.0, landing_xz.y)
	var moon_edge_flat := moon_center_flat + Vector3(20_000.0, 0.0, 0.0)
	var moon_center_sample := _call_surface_sampler(
		moon, moon_sampler_names, moon_center_flat)
	var moon_edge_sample := _call_surface_sampler(
		moon, moon_sampler_names, moon_edge_flat)
	var expected_moon_sag_m := -_sphere_surface_y(
		20_000.0, 0.0, EXPECTED_MOON_RADIUS_KM * 1000.0)
	var sampled_moon_sag_m := INF
	if bool(moon_center_sample.found) and bool(moon_edge_sample.found):
		sampled_moon_sag_m = (moon_center_sample.point as Vector3).y \
			- (moon_edge_sample.point as Vector3).y
	_check(bool(moon_center_sample.found) and bool(moon_edge_sample.found) \
			and absf(sampled_moon_sag_m - expected_moon_sag_m) <= 2.0 \
			and (moon_center_sample.point as Vector3) \
				.distance_to(moon_center_flat) <= 0.01,
		"Moon astronomical sampler is tangent to the 1,737.4 km-radius voyage sphere",
		"method=%s expected_20km_sag=%.3f sampled=%.3f" % [
			str(moon_center_sample.method), expected_moon_sag_m,
			sampled_moon_sag_m])

	var earth_globe := rocket.voyage_visuals.earth_visual as MeshInstance3D
	var moon_globe := rocket.voyage_visuals.moon_visual as MeshInstance3D
	var earth_sphere := earth_globe.mesh as SphereMesh
	var moon_sphere := moon_globe.mesh as SphereMesh
	var earth_material: Material = earth_globe.material_override
	var moon_material: Material = moon_globe.material_override
	var earth_texture: Texture2D = null
	var moon_texture: Texture2D = null
	var earth_anisotropic := false
	var moon_anisotropic := false
	if earth_material is StandardMaterial3D:
		earth_texture = (earth_material as StandardMaterial3D).albedo_texture
		earth_anisotropic = (earth_material as StandardMaterial3D).texture_filter \
			== BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	elif earth_material is ShaderMaterial:
		earth_texture = (earth_material as ShaderMaterial) \
			.get_shader_parameter("planet_atlas") as Texture2D
		# The shader declaration is the render contract for custom materials.
		earth_anisotropic = (earth_material as ShaderMaterial).shader.code \
			.contains("filter_linear_mipmap_anisotropic")
	if moon_material is StandardMaterial3D:
		moon_texture = (moon_material as StandardMaterial3D).albedo_texture
		moon_anisotropic = (moon_material as StandardMaterial3D).texture_filter \
			== BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	elif moon_material is ShaderMaterial:
		moon_texture = (moon_material as ShaderMaterial) \
			.get_shader_parameter("planet_atlas") as Texture2D
		moon_anisotropic = (moon_material as ShaderMaterial).shader.code \
			.contains("filter_linear_mipmap_anisotropic")
	var tessellation_ok := earth_sphere and moon_sphere \
		and earth_sphere.radial_segments >= MIN_GLOBE_RADIAL_SEGMENTS \
		and earth_sphere.rings >= MIN_GLOBE_RINGS \
		and moon_sphere.radial_segments >= MIN_GLOBE_RADIAL_SEGMENTS \
		and moon_sphere.rings >= MIN_GLOBE_RINGS
	_check(tessellation_ok,
		"Earth and Moon limbs have high-detail sphere tessellation",
		"earth=%sx%s moon=%sx%s minimum=%sx%s" % [
			earth_sphere.radial_segments if earth_sphere else -1,
			earth_sphere.rings if earth_sphere else -1,
			moon_sphere.radial_segments if moon_sphere else -1,
			moon_sphere.rings if moon_sphere else -1,
			MIN_GLOBE_RADIAL_SEGMENTS, MIN_GLOBE_RINGS])
	var texture_quality_ok := earth_texture and moon_texture \
		and earth_texture.get_width() >= MIN_ATLAS_WIDTH \
		and earth_texture.get_height() >= MIN_ATLAS_HEIGHT \
		and moon_texture.get_width() >= MIN_ATLAS_WIDTH \
		and moon_texture.get_height() >= MIN_ATLAS_HEIGHT \
		and earth_anisotropic and moon_anisotropic
	_check(texture_quality_ok,
		"both planet globes use 4K anisotropic mipmapped atlases",
		"earth=%sx%s moon=%sx%s" % [
			earth_texture.get_width() if earth_texture else -1,
			earth_texture.get_height() if earth_texture else -1,
			moon_texture.get_width() if moon_texture else -1,
			moon_texture.get_height() if moon_texture else -1])

	# Gameplay now owns a compact, complete sphere. The astronomical sampler
	# above remains a voyage contract; a finite tangent cap would leave players
	# without terrain or collision after crossing the old landing-zone boundary.
	var playable_constants: Dictionary = moon_script.get_script_constant_map()
	var playable_radius := float(playable_constants.get("PLAYABLE_RADIUS_METERS", -1.0))
	var playable_center: Vector3 = playable_constants.get("PLAYABLE_CENTER", Vector3.ZERO)
	var lunar_surface := moon.terrain_mesh as MeshInstance3D
	var surface_arrays := _mesh_arrays(lunar_surface)
	var surface_vertices: PackedVector3Array = surface_arrays[Mesh.ARRAY_VERTEX] \
		if surface_arrays.size() == Mesh.ARRAY_MAX else PackedVector3Array()
	var surface_normals: PackedVector3Array = surface_arrays[Mesh.ARRAY_NORMAL] \
		if surface_arrays.size() == Mesh.ARRAY_MAX else PackedVector3Array()
	var surface_indices: PackedInt32Array = surface_arrays[Mesh.ARRAY_INDEX] \
		if surface_arrays.size() == Mesh.ARRAY_MAX else PackedInt32Array()
	var closed_sphere_ok := playable_radius >= 400.0 and playable_radius <= 500.0 \
		and surface_vertices.size() >= 18_000 \
		and surface_normals.size() == surface_vertices.size()
	var minimum_radius := INF
	var maximum_radius := -INF
	var hemisphere_coverage: Dictionary = {}
	for index in range(surface_vertices.size()):
		var radial := surface_vertices[index] - playable_center
		minimum_radius = minf(minimum_radius, radial.length())
		maximum_radius = maxf(maximum_radius, radial.length())
		closed_sphere_ok = closed_sphere_ok \
			and absf(radial.length() - playable_radius) < 40.0 \
			and surface_normals[index].dot(radial.normalized()) > 0.85
		for axis in range(3):
			if absf(radial[axis]) > playable_radius * 0.95:
				hemisphere_coverage[Vector2i(axis, 1 if radial[axis] > 0.0 else -1)] = true
	var edges: Dictionary = {}
	for triangle in range(0, surface_indices.size(), 3):
		for corner in range(3):
			var a := surface_indices[triangle + corner]
			var b := surface_indices[triangle + (corner + 1) % 3]
			var edge := Vector2i(mini(a, b), maxi(a, b))
			edges[edge] = int(edges.get(edge, 0)) + 1
	for count in edges.values():
		closed_sphere_ok = closed_sphere_ok and int(count) == 2
	closed_sphere_ok = closed_sphere_ok and hemisphere_coverage.size() == 6 \
		and surface_vertices.size() - edges.size() + surface_indices.size() / 3 == 2
	_check(closed_sphere_ok,
		"generated lunar ground is a welded sphere with all six hemispheres and outward normals",
		"vertices=%d radius=%.1f..%.1f hemispheres=%d" % [surface_vertices.size(),
			minimum_radius, maximum_radius, hemisphere_coverage.size()])
	var terrain_collision := (moon.terrain_body.get_child(0) as CollisionShape3D).shape \
		as ConcavePolygonShape3D
	var one_surface_ok: bool = lunar_surface != null \
		and moon.lunar_visual_horizon == lunar_surface \
		and moon.lunar_far_surface_fill == lunar_surface \
		and lunar_surface.visible \
		and surface_vertices.size() <= 25_000 \
		and surface_indices.size() / 3 <= 50_000 \
		and terrain_collision != null \
		and terrain_collision.get_faces() == lunar_surface.mesh.get_faces()
	_check(one_surface_ok,
		"one bounded lunar surface supplies matching rendered and collision geometry",
		"vertices=%d triangles=%d surface_visible=%s" % [surface_vertices.size(),
			surface_indices.size() / 3, lunar_surface.visible])

	# The Moon cannot dissolve into local terrain. It remains opaque while the
	# camera and scaled geometry carry it behind the matching curved surface.
	for fps in [30, 60]:
		var outbound_result := _moon_proxy_sweep(rocket, rocket_script, fps,
			float(constants.get("TRANSFER_PAN_START_SECONDS", 28.0)),
			float(rocket_script.OUTBOUND_DURATION_SECONDS), true)
		_check(bool(outbound_result.opaque) \
				and bool(outbound_result.continuous),
			"%d FPS Moon approach uses opaque continuous geometry, never alpha" % fps,
			"first_nonopaque=%.3f max_relative_step=%.5f at=%.3f" % [
				float(outbound_result.first_nonopaque_elapsed),
				float(outbound_result.max_step),
				float(outbound_result.max_step_elapsed)])
		var return_result := _moon_proxy_sweep(rocket, rocket_script, fps,
			0.0, 12.0, false)
		_check(bool(return_result.opaque) and bool(return_result.continuous),
			"%d FPS Moon departure reveals curvature by distance, never alpha" % fps,
			"first_nonopaque=%.3f max_relative_step=%.5f at=%.3f" % [
				float(return_result.first_nonopaque_elapsed),
				float(return_result.max_step),
				float(return_result.max_step_elapsed)])

	var flip_start := float(constants.get("LUNAR_FLIP_START_SECONDS", 46.0))
	var descent_start := float(rocket_script.OUTBOUND_PHASE_TIMES[2])
	for fps in [30, 60]:
		rocket.outbound = true
		var landing_result := _landing_motion_sweep(rocket, rocket_script, fps,
			flip_start, descent_start)
		_check(bool(landing_result.continuous) \
				and float(landing_result.visible_flip_degrees) >= 45.0 \
				and float(landing_result.initial_up_dot) < -0.70 \
				and absf(float(landing_result.midpoint_up_dot)) < 0.50 \
				and float(landing_result.upright_dot) > 0.999 \
				and bool(landing_result.descent_monotonic) \
				and bool(landing_result.descent_upright),
			"%d FPS approach visibly flips upright, then descends without a snap" % fps,
			"flip=%.2fdeg start_dot=%.3f mid_dot=%.3f upright=%.5f max_rot_step=%.3fdeg max_pos_step=%.3f" % [
				float(landing_result.visible_flip_degrees),
				float(landing_result.initial_up_dot),
				float(landing_result.midpoint_up_dot),
				float(landing_result.upright_dot),
				float(landing_result.max_rotation_step_degrees),
				float(landing_result.max_position_step)])

	stage.queue_free()
	await process_frame
	await process_frame
	print("PLANETCURVATURETEST %d/%d %s" % [passed, total,
		"PASS" if passed == total else "FAIL"])
	quit(0 if passed == total else 1)
