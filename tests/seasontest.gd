extends Node
## Deterministic calendar, accelerated-day, seasonal-rendering and scarf checks.

const TEST_PUPPET_START_ID := 9876

var passed := 0
var total := 0


func run(main) -> void:
	var world: World = main.world
	if not world or not is_instance_valid(world) or not world.local_player:
		_check(false, "a normal solo world exists for seasonal verification")
		_finish()
		return

	# Northern-hemisphere civil seasons, matching the local calendar policy.
	_check(_months_match([3, 4, 5], SeasonalCycle.Season.SPRING),
		"March through May map to spring")
	_check(_months_match([6, 7, 8], SeasonalCycle.Season.SUMMER),
		"June through August map to summer")
	_check(_months_match([9, 10, 11], SeasonalCycle.Season.AUTUMN),
		"September through November map to autumn")
	_check(_months_match([12, 1, 2], SeasonalCycle.Season.WINTER),
		"December through February map to winter")

	_check(is_equal_approx(SeasonalCycle.DAY_LENGTH_SECONDS, 3600.0) \
			and is_equal_approx(
				SeasonalCycle.hour_after_elapsed(3.25, 3600.0), 3.25),
		"one complete game day lasts exactly 3600 real seconds and wraps cleanly")
	_check(is_equal_approx(
			SeasonalCycle.hour_after_elapsed(3.0, 900.0), 9.0) \
			and is_equal_approx(
				SeasonalCycle.hour_after_elapsed(3.0, 1800.0), 15.0),
		"quarter- and half-cycle elapsed time advance six and twelve game hours")
	_check(is_equal_approx(SeasonalCycle.hour_for_unix_time(0.0), 0.0) \
			and is_equal_approx(
				SeasonalCycle.hour_for_unix_time(900.0), 6.0) \
			and is_equal_approx(
				SeasonalCycle.hour_for_unix_time(3600.0), 0.0) \
			and is_equal_approx(
				SeasonalCycle.hour_for_unix_time(12_345.0),
				SeasonalCycle.hour_for_unix_time(12_345.0)),
		"epoch-derived game time is deterministic, synchronized, and hourly-cycle wrapped")
	var original_cycle_hour := Net.authoritative_cycle_hour()
	var cycle_anchor_accepted := Net.set_authoritative_cycle_hour(29.5)
	var anchored_cycle_hour := Net.authoritative_cycle_hour()
	var next_cycle_hour := Net.authoritative_cycle_hour()
	_check(cycle_anchor_accepted and anchored_cycle_hour > 5.49 \
			and anchored_cycle_hour < 5.55 and next_cycle_hour >= anchored_cycle_hour \
			and next_cycle_hour - anchored_cycle_hour < 0.01,
		"the authoritative cycle API wraps anchors and advances monotonically")
	Net.set_authoritative_cycle_hour(original_cycle_hour)
	_check(absf(SeasonalCycle.solar_elevation_for_hour(6.0)) < 0.0001 \
			and SeasonalCycle.solar_elevation_for_hour(12.0) > 0.999 \
			and absf(SeasonalCycle.solar_elevation_for_hour(18.0)) < 0.0001 \
			and SeasonalCycle.solar_elevation_for_hour(0.0) < -0.999,
		"solar elevation has sunrise, noon, sunset, and midnight in the expected order")
	_check(SeasonalCycle.weather_for_season(SeasonalCycle.Season.SPRING) \
				== SeasonalCycle.Weather.RAIN \
			and SeasonalCycle.weather_for_season(SeasonalCycle.Season.SUMMER) \
				== SeasonalCycle.Weather.CLEAR \
			and SeasonalCycle.weather_for_season(SeasonalCycle.Season.AUTUMN) \
				== SeasonalCycle.Weather.FALLING_LEAVES \
			and SeasonalCycle.weather_for_season(SeasonalCycle.Season.WINTER) \
				== SeasonalCycle.Weather.SNOW,
		"each real-life season selects its intended weather")

	# Public clock overrides make lighting assertions independent of wall time.
	world.set_time_of_day_override(3.0)
	world._update_day_night(900.0)
	_check(is_equal_approx(world.time_of_day_hours, 9.0),
		"the live World clock advances at the same one-hour-cycle rate")

	# The visible sky is one cached shader/atlas. Moonlight remains a separate
	# non-shadowing directional so visual richness never adds a shadow pass.
	world.set_season_override(SeasonalCycle.Season.SUMMER)
	var celestial: CelestialSky = world._celestial_sky
	var celestial_material: ShaderMaterial = celestial.get_material() \
		if celestial else null
	var celestial_resource_ids: Dictionary = celestial.resource_instance_ids() \
		if celestial else {}
	_check(celestial != null and celestial_material != null \
			and celestial_material == world._sky_material \
			and world._environment.sky.sky_material == celestial_material,
		"one custom celestial material owns the rendered sky")
	_check(celestial.star_count() >= 700 and celestial.star_count() <= 1200,
		"the deterministic star catalogue is rich but bounded")
	var constellation_names := celestial.constellation_names()
	_check("Big Dipper" in constellation_names \
			and "Cassiopeia" in constellation_names \
			and "Orion" in constellation_names \
			and celestial.constellation_segment_count() >= 18 \
			and celestial.constellation_segment_count() <= 36 \
			and celestial.constellation_strength() > 0.0 \
			and celestial.constellation_strength() <= 0.25,
		"recognizable constellations use bounded subtle linework")
	_check(celestial.planet_count() >= 2 and celestial.planet_count() <= 4,
		"the sky contains a small bounded set of planets")
	_check(celestial.moon_angular_diameter_degrees() >= 0.85 \
			and celestial.moon_angular_diameter_degrees() <= 1.20 \
			and celestial.moon_crater_count() >= 4 \
			and celestial.moon_crater_count() <= 8,
		"the moon is moderately enlarged with bounded crater detail")
	var sun_radius_uniform := float(
		celestial_material.get_shader_parameter("sun_radius_sine"))
	var sun_edge_softness_uniform := float(
		celestial_material.get_shader_parameter("sun_disc_edge_softness"))
	var sun_half_opacity_radius := ((1.0 - sun_edge_softness_uniform) \
		+ (1.0 + sun_edge_softness_uniform)) * 0.5
	# Measure the implementation this replaces rather than trusting the new
	# constant to define its own baseline. The legacy disc's smoothstep reached
	# half opacity at the midpoint of these two cosine thresholds.
	var legacy_sun_diameter_degrees := rad_to_deg(2.0 * acos(
		(0.999980780 + 0.999988480) * 0.5))
	_check(is_equal_approx(celestial.sun_apparent_diameter_degrees(),
			legacy_sun_diameter_degrees * 3.0) \
			and is_equal_approx(CelestialSky.SUN_BASE_DIAMETER_DEGREES,
				legacy_sun_diameter_degrees) \
			and is_equal_approx(celestial.sun_angular_diameter_degrees(),
				celestial.sun_apparent_diameter_degrees()) \
			and is_equal_approx(celestial.sun_diameter_scale(), 3.0) \
			and is_equal_approx(sun_radius_uniform, sin(deg_to_rad(
				celestial.sun_apparent_diameter_degrees() * 0.5))) \
			and is_equal_approx(sun_edge_softness_uniform,
				CelestialSky.SUN_DISC_EDGE_SOFTNESS) \
			and is_equal_approx(sun_half_opacity_radius, 1.0),
		"the sun is exactly three-times wider at its symmetric half-opacity contour")
	var pre_zenith_direction := (Vector3.UP + Vector3.FORWARD * 0.001).normalized()
	var post_zenith_direction := (Vector3.UP - Vector3.FORWARD * 0.001).normalized()
	var pre_zenith_face_up := CelestialSky.sun_face_up_for_direction(
		pre_zenith_direction)
	var zenith_face_up := CelestialSky.sun_face_up_for_direction(Vector3.UP)
	var post_zenith_face_up := CelestialSky.sun_face_up_for_direction(
		post_zenith_direction)
	_check(absf(pre_zenith_face_up.dot(pre_zenith_direction)) < 0.0001 \
			and absf(zenith_face_up.dot(Vector3.UP)) < 0.0001 \
			and absf(post_zenith_face_up.dot(post_zenith_direction)) < 0.0001 \
			and pre_zenith_face_up.dot(zenith_face_up) > 0.9999 \
			and zenith_face_up.dot(post_zenith_face_up) > 0.9999,
		"the sun face tangent stays orthogonal and continuous across zenith")
	var expected_world_smile := CelestialSky.sun_smiley_for_seed(Gen.world_seed)
	var smile_uniform := float(
		celestial_material.get_shader_parameter("sun_smiley_enabled"))
	var peer_sky_a: CelestialSky = CelestialSky.new(Gen.world_seed)
	var peer_sky_b: CelestialSky = CelestialSky.new(Gen.world_seed)
	var peer_resource_ids_a := peer_sky_a.resource_instance_ids()
	var peer_resource_ids_b := peer_sky_b.resource_instance_ids()
	_check(celestial.sun_world_seed() == Gen.world_seed \
			and celestial.sun_smiley_enabled() == expected_world_smile \
			and peer_sky_a.sun_smiley_enabled() == expected_world_smile \
			and peer_sky_b.sun_smiley_enabled() == expected_world_smile \
			and is_equal_approx(smile_uniform, 1.0 if expected_world_smile else 0.0) \
			and is_equal_approx(float(peer_sky_a.get_material().get_shader_parameter(
				"sun_smiley_enabled")), smile_uniform) \
			and is_equal_approx(float(peer_sky_b.get_material().get_shader_parameter(
				"sun_smiley_enabled")), smile_uniform),
		"the shared world seed gives every multiplayer peer the same stable sun face")
	_check(peer_resource_ids_a.shader == celestial_resource_ids.shader \
			and peer_resource_ids_b.shader == celestial_resource_ids.shader \
			and peer_resource_ids_a.atlas == celestial_resource_ids.atlas \
			and peer_resource_ids_b.atlas == celestial_resource_ids.atlas \
			and peer_resource_ids_a.material != celestial_resource_ids.material \
			and peer_resource_ids_b.material != celestial_resource_ids.material \
			and peer_resource_ids_a.material != peer_resource_ids_b.material,
		"peer skies share the bounded shader and atlas but keep independent uniforms")
	peer_sky_a.update_celestials(0.8, 0.7, Vector3.UP, 0.0, 9.0,
		Vector3(0.2, 0.8, -0.4))
	var expected_peer_sun_visibility := 0.8 * pow(0.7, 3.0)
	_check(is_equal_approx(peer_sky_a.sun_visibility(),
			expected_peer_sun_visibility) \
			and is_equal_approx(float(peer_sky_a.get_material().get_shader_parameter(
				"sun_visibility")), expected_peer_sun_visibility) \
			and CelestialSky.SKY_SHADER.find(
				"sun_disc * sun_visibility") >= 0 \
			and CelestialSky.SKY_SHADER.find(
				"sun_halo * sun_visibility") >= 0,
		"weather visibility attenuates the complete sun disc, face, and halo")
	peer_sky_a = null
	peer_sky_b = null
	var smiling_seed_count := 0
	for seed_value in range(CelestialSky.SUN_SMILE_BUCKETS):
		if CelestialSky.sun_smiley_for_seed(seed_value):
			smiling_seed_count += 1
	_check(smiling_seed_count == CelestialSky.SUN_SMILE_THRESHOLD \
			and CelestialSky.SUN_SMILE_THRESHOLD == int(
				CelestialSky.SUN_SMILE_CHANCE * CelestialSky.SUN_SMILE_BUCKETS) \
			and is_equal_approx(float(smiling_seed_count) \
				/ float(CelestialSky.SUN_SMILE_BUCKETS),
				CelestialSky.SUN_SMILE_CHANCE),
		"the deterministic broad seed sample selects exactly thirty percent smiley suns")
	var celestial_catalog_signature := celestial.catalog_signature()
	_check(not celestial_catalog_signature.is_empty(),
		"the generated celestial catalogue has a deterministic signature")
	_check(celestial_resource_ids.size() >= 2 \
			and celestial_resource_ids.size() <= 3 \
			and world._environment.sky.process_mode \
				== Sky.PROCESS_MODE_INCREMENTAL \
			and CelestialSky.SKY_SHADER.find("TIME") < 0,
		"the incremental sky uses a bounded cache without real-time shader updates")

	world.set_time_of_day_override(12.0)
	var noon_daylight := world.daylight_amount
	var noon_sun_energy := world._sun.light_energy
	var noon_moon_energy := world._moon.light_energy
	var noon_moon_visual_strength := world.moon_visual_strength()
	var noon_night_visibility := celestial.night_visibility()
	var noon_weather_visibility := celestial.weather_visibility()
	var noon_shader_moon_visibility := float(
		celestial_material.get_shader_parameter("moon_visibility"))
	var noon_shadow_casters := _count_shadow_directionals(world)
	world.set_time_of_day_override(0.0)
	var midnight_daylight := world.daylight_amount
	var midnight_sun_energy := world._sun.light_energy
	var midnight_moon_energy := world._moon.light_energy
	var midnight_moon_visual_strength := world.moon_visual_strength()
	var midnight_night_visibility := celestial.night_visibility()
	var midnight_weather_visibility := celestial.weather_visibility()
	var midnight_shader_moon_visibility := float(
		celestial_material.get_shader_parameter("moon_visibility"))
	var midnight_moon_direction := world.moon_source_direction()
	var midnight_sun_direction := world._sun.global_basis.z.normalized()
	var shader_moon_direction := Vector3(
		celestial_material.get_shader_parameter("moon_direction"))
	var midnight_palette := celestial.palette_colors()
	var midnight_top: Color = midnight_palette.top
	var midnight_horizon: Color = midnight_palette.horizon
	var midnight_shadow_casters := _count_shadow_directionals(world)
	_check(noon_daylight > 0.98 and midnight_daylight < 0.02 \
			and noon_sun_energy > midnight_sun_energy \
			and midnight_moon_energy > noon_moon_energy,
		"runtime noon is sunlit while midnight is moonlit")
	_check(noon_night_visibility <= 0.01 \
			and noon_weather_visibility >= 0.99 \
			and noon_moon_visual_strength <= 0.015 \
			and noon_shader_moon_visibility <= 0.01 \
			and midnight_night_visibility >= 0.95 \
			and midnight_weather_visibility >= 0.99 \
			and midnight_shader_moon_visibility > noon_shader_moon_visibility,
		"stars, planets, constellations, and the moon fade out in daylight")
	_check(_is_midnight_blue(midnight_top) \
			and _is_midnight_blue(midnight_horizon) \
			and midnight_horizon.get_luminance() \
				> midnight_top.get_luminance(),
		"clear midnight uses a readable deep-blue sky gradient")
	_check(not world._moon.shadow_enabled \
			and world._moon.sky_mode \
				== DirectionalLight3D.SKY_MODE_LIGHT_ONLY \
			and noon_shadow_casters == 1 \
			and midnight_shadow_casters <= 1,
		"the cratered sky adds no directional shadow pass")
	_check(shader_moon_direction.normalized().dot(
			midnight_moon_direction) > 0.9999,
		"the cratered moon follows the moonlight source direction")
	_check(midnight_moon_direction.dot(midnight_sun_direction) < -0.999,
		"the moon remains opposite the sun in the celestial orbit")
	_check(celestial.sun_smiley_enabled() == expected_world_smile \
			and is_equal_approx(float(celestial_material.get_shader_parameter(
				"sun_smiley_enabled")), smile_uniform),
		"the per-world sun face remains unchanged across noon and midnight updates")
	world.set_time_of_day_override(3.0)
	var advanced_shader_moon_direction := Vector3(
		celestial_material.get_shader_parameter("moon_direction"))
	_check(midnight_moon_direction.dot(world.moon_source_direction()) < 0.95 \
			and advanced_shader_moon_direction.normalized().dot(
				world.moon_source_direction()) > 0.9999,
		"the visible moon advances through the sky with game time")
	world.set_season_override(SeasonalCycle.Season.SUMMER)
	world.set_time_of_day_override(0.0)
	var clear_night_moon_energy := world._moon.light_energy
	var clear_night_moon_visual_strength := world.moon_visual_strength()
	var clear_night_weather_visibility := celestial.weather_visibility()
	var clear_night_shader_moon_visibility := float(
		celestial_material.get_shader_parameter("moon_visibility"))
	world.set_season_override(SeasonalCycle.Season.SPRING)
	var rainy_night_moon_energy := world._moon.light_energy
	var rainy_night_moon_visual_strength := world.moon_visual_strength()
	var rainy_night_weather_visibility := celestial.weather_visibility()
	var rainy_night_shader_moon_visibility := float(
		celestial_material.get_shader_parameter("moon_visibility"))
	world.set_season_override(SeasonalCycle.Season.WINTER)
	var snowy_night_moon_visual_strength := world.moon_visual_strength()
	var snowy_night_weather_visibility := celestial.weather_visibility()
	var snowy_night_shader_moon_visibility := float(
		celestial_material.get_shader_parameter("moon_visibility"))
	_check(clear_night_moon_energy > 0.0 and rainy_night_moon_energy > 0.0 \
			and rainy_night_moon_energy < clear_night_moon_energy,
		"rainy nights dim moonlight below a clear summer night")
	_check(clear_night_weather_visibility >= 0.99 \
			and rainy_night_weather_visibility > 0.0 \
			and rainy_night_weather_visibility \
				< clear_night_weather_visibility \
			and rainy_night_shader_moon_visibility \
				< clear_night_shader_moon_visibility \
			and rainy_night_moon_visual_strength \
				< clear_night_moon_visual_strength,
		"rain dims every visible celestial below a clear night")
	_check(snowy_night_moon_visual_strength > 0.0 \
			and snowy_night_moon_visual_strength \
				< clear_night_moon_visual_strength \
			and snowy_night_weather_visibility > 0.0 \
			and snowy_night_weather_visibility \
				< clear_night_weather_visibility \
			and snowy_night_shader_moon_visibility > 0.0 \
			and snowy_night_shader_moon_visibility \
				< clear_night_shader_moon_visibility,
		"snow dims every visible celestial without removing it")
	world.set_season_override(SeasonalCycle.Season.SUMMER)

	var weather_system: SeasonalWeather = world.seasonal_weather
	var weather_particles: GPUParticles3D = (
		weather_system.particles if weather_system else null)
	_check(weather_system != null and weather_particles != null \
			and weather_system.get_child_count() == 1 \
			and weather_particles.fixed_fps == 30 \
			and not weather_particles.local_coords \
			and weather_particles.cast_shadow \
				== GeometryInstance3D.SHADOW_CASTING_SETTING_OFF,
		"one bounded 30 FPS non-shadowing GPU weather field follows the player")
	_check(_particle_budgets_are_bounded(),
		"rain, leaves, and snow use positive performance < normal < high particle budgets")

	# Material references and streamed chunks must survive season switches in place.
	var season_materials: Array[ShaderMaterial] = [
		Visuals.ground_material(),
		Visuals.trunk_material(),
		Visuals.grass_material(),
		Visuals.rock_material(),
		Visuals.foliage_lod_material(),
		Visuals.far_ground_material(),
		Visuals.far_jungle_material(),
	]
	var material_ids: Array[int] = []
	for material in season_materials:
		material_ids.append(material.get_instance_id())
	var shared_material_count := Visuals._shared.size()
	var foliage_material_count := Visuals._foliage.size()
	var chunk_ids := {}
	for key in world.chunks:
		var chunk := world.chunks[key] as Chunk
		if chunk and is_instance_valid(chunk):
			chunk_ids[key] = chunk.get_instance_id()
	var original_chunk_count := world.chunks.size()
	var weather_system_id := weather_system.get_instance_id()
	var weather_particles_id := weather_particles.get_instance_id()

	world.set_season_override(SeasonalCycle.Season.SPRING)
	_check(_season_amounts_match(Vector3(1.0, 0.0, 0.0)) \
			and _foliage_parameters_match(1.0, 0.0, 0.0) \
			and _runtime_weather_matches(world, SeasonalCycle.Weather.RAIN),
		"spring enables fresh foliage and bounded rain")
	world.set_season_override(SeasonalCycle.Season.SUMMER)
	_check(_season_amounts_match(Vector3.ZERO) \
			and _foliage_parameters_match(0.0, 0.0, 0.0) \
			and _runtime_weather_matches(world, SeasonalCycle.Weather.CLEAR),
		"summer restores green foliage and disables precipitation")
	world.set_season_override(SeasonalCycle.Season.AUTUMN)
	_check(_season_amounts_match(Vector3(0.0, 1.0, 0.0)) \
			and _foliage_parameters_match(0.0, 1.0, 0.0) \
			and _runtime_weather_matches(
				world, SeasonalCycle.Weather.FALLING_LEAVES),
		"autumn recolours near and far foliage and emits falling leaves")
	world.set_season_override(SeasonalCycle.Season.WINTER)
	_check(_season_amounts_match(Vector3(0.0, 0.0, 1.0)) \
			and _foliage_parameters_match(0.0, 0.0, 1.0) \
			and _snow_parameters_match(1.0) \
			and _runtime_weather_matches(world, SeasonalCycle.Weather.SNOW),
		"winter applies snow to near/far world materials and emits snowfall")
	var weather_process_ids := {}
	var weather_mesh_ids := {}
	for weather_kind in weather_system._process_materials:
		var cached_process: Resource = weather_system._process_materials[weather_kind]
		var cached_mesh: Resource = weather_system._particle_meshes[weather_kind]
		weather_process_ids[weather_kind] = cached_process.get_instance_id()
		weather_mesh_ids[weather_kind] = cached_mesh.get_instance_id()

	# Ensure all actor paths exist, then verify their single shared scarf resource.
	var ai := world.ai_opponent as MonkeyPlayer
	if not ai:
		ai = world.spawn_solo_ai() as MonkeyPlayer
	var puppet_id := TEST_PUPPET_START_ID
	while world.puppets.has(puppet_id):
		puppet_id += 1
	var puppet := world.spawn_puppet(puppet_id, "Season Test Monkey")
	var local_rig: MonkeyRig = world.local_player.rig
	var ai_rig: MonkeyRig = ai.rig if ai else null
	var puppet_rig: MonkeyRig = puppet.rig if puppet else null
	_check(local_rig != null and ai_rig != null and puppet_rig != null \
			and local_rig.has_visible_winter_scarf() \
			and ai_rig.has_visible_winter_scarf() \
			and puppet_rig.has_visible_winter_scarf(),
		"winter scarves appear on the local player, solo AI, and network puppet")
	_check(_scarves_share_bounded_resources(local_rig, ai_rig, puppet_rig),
		"all living scarves share one mesh, cast no shadows, and the local scarf uses the body-only layer")

	var ragdoll := MonkeyRagdoll.new()
	ragdoll.configure("Winter Ragdoll", world.local_player.global_position \
		+ Vector3(2.0, 1.0, 2.0), 0.0, Vector3.ZERO, Vector3.ZERO, true)
	world.add_child(ragdoll)
	await get_tree().process_frame
	_check(ragdoll.winter_scarf != null and ragdoll.winter_scarf.visible \
			and ragdoll.winter_scarf.get_parent() == ragdoll.torso \
			and ragdoll.winter_scarf.mesh.get_instance_id() \
				== local_rig.winter_scarf.mesh.get_instance_id(),
		"detached-head ragdolls keep the same winter scarf on their physics torso")
	world.set_season_override(SeasonalCycle.Season.SUMMER)
	_check(not ragdoll.winter_scarf.visible,
		"an existing ragdoll hides its scarf outside winter")
	world.set_season_override(SeasonalCycle.Season.WINTER)

	# Repeated transitions must update state only, never rebuild streamed geometry,
	# duplicate shared render materials, or replace the persistent weather emitter.
	# Puppet construction can legitimately populate previously-unused shared actor
	# materials, so take the growth baseline after every actor path exists.
	shared_material_count = Visuals._shared.size()
	foliage_material_count = Visuals._foliage.size()
	for transition_hour in [12.0, 0.0, 6.35, 21.0, 0.0]:
		world.set_time_of_day_override(transition_hour)
	for next_season in [
		SeasonalCycle.Season.SUMMER,
		SeasonalCycle.Season.AUTUMN,
		SeasonalCycle.Season.WINTER,
		SeasonalCycle.Season.SPRING,
		SeasonalCycle.Season.SUMMER,
	]:
		world.set_season_override(next_season)
	var material_identity_stable := season_materials.size() == material_ids.size()
	for index in range(season_materials.size()):
		material_identity_stable = material_identity_stable \
			and season_materials[index].get_instance_id() == material_ids[index]
	_check(material_identity_stable \
			and Visuals._shared.size() == shared_material_count \
			and Visuals._foliage.size() == foliage_material_count,
		"season toggles mutate cached shader parameters without material growth")
	_check(world.chunks.size() == original_chunk_count \
			and _chunk_instances_match(world, chunk_ids),
		"season toggles preserve every streamed chunk instance")
	_check(world.seasonal_weather.get_instance_id() == weather_system_id \
			and world.seasonal_weather.particles.get_instance_id() \
				== weather_particles_id \
			and _weather_resources_match(world.seasonal_weather,
				weather_process_ids, weather_mesh_ids),
		"all weather types reuse one emitter and a bounded resource cache")
	_check(world._celestial_sky == celestial \
			and celestial.get_material() == celestial_material \
			and celestial.resource_instance_ids() == celestial_resource_ids \
			and celestial.catalog_signature() == celestial_catalog_signature,
		"time and season transitions preserve one cached celestial sky")
	_check(not local_rig.has_visible_winter_scarf() \
			and not ai_rig.has_visible_winter_scarf() \
			and not puppet_rig.has_visible_winter_scarf(),
		"non-winter transitions hide every living scarf")
	# Do not retain test-local references to renderer resources while the scene
	# tree shuts down; World remains their sole owner after the assertions above.
	celestial_material = null
	celestial = null

	world.remove_puppet(puppet_id)
	ragdoll.queue_free()
	world.clear_time_of_day_override()
	world.clear_season_override()
	await get_tree().process_frame
	_finish()


func _months_match(months: Array, expected_season: int) -> bool:
	for month in months:
		if SeasonalCycle.season_for_month(int(month)) != expected_season:
			return false
	return true


func _particle_budgets_are_bounded() -> bool:
	for weather_kind in [SeasonalCycle.Weather.RAIN,
			SeasonalCycle.Weather.FALLING_LEAVES,
			SeasonalCycle.Weather.SNOW]:
		var performance := SeasonalWeather.particle_budget(weather_kind, false, true)
		var normal := SeasonalWeather.particle_budget(weather_kind, false, false)
		var high := SeasonalWeather.particle_budget(weather_kind, true, false)
		if performance <= 0 or performance >= normal or normal >= high or high > 640:
			return false
	return SeasonalWeather.particle_budget(
		SeasonalCycle.Weather.CLEAR, true, false) == 0


func _runtime_weather_matches(world: World, expected_weather: int) -> bool:
	var system := world.seasonal_weather
	if not system or not system.particles or world.weather != expected_weather \
			or system.weather != expected_weather:
		return false
	if expected_weather == SeasonalCycle.Weather.CLEAR:
		return not system.particles.emitting and system.particles.amount == 1
	return system.particles.emitting \
		and system.particles.amount == SeasonalWeather.particle_budget(
			expected_weather, world._high_effects,
			world._fullscreen_performance)


func _season_amounts_match(expected: Vector3) -> bool:
	return Visuals.season_amounts().is_equal_approx(expected)


func _foliage_parameters_match(spring: float, autumn: float,
		snow: float) -> bool:
	for material in [Visuals.foliage_lod_material(),
			Visuals.far_jungle_material()]:
		if not _shader_float_matches(material, "spring_amount", spring) \
				or not _shader_float_matches(material, "autumn_amount", autumn) \
				or not _shader_float_matches(material, "snow_amount", snow):
			return false
	return true


func _snow_parameters_match(expected: float) -> bool:
	for material in [Visuals.ground_material(), Visuals.trunk_material(),
			Visuals.grass_material(), Visuals.rock_material(),
			Visuals.foliage_lod_material(), Visuals.far_ground_material(),
			Visuals.far_jungle_material()]:
		if not _shader_float_matches(material, "snow_amount", expected):
			return false
	return true


func _shader_float_matches(material: ShaderMaterial, parameter: StringName,
		expected: float) -> bool:
	return material != null and is_equal_approx(
		float(material.get_shader_parameter(parameter)), expected)


func _scarves_share_bounded_resources(local_rig: MonkeyRig,
		ai_rig: MonkeyRig, puppet_rig: MonkeyRig) -> bool:
	if not local_rig or not ai_rig or not puppet_rig \
			or not local_rig.winter_scarf or not ai_rig.winter_scarf \
			or not puppet_rig.winter_scarf:
		return false
	var shared_mesh_id := local_rig.winter_scarf.mesh.get_instance_id()
	for scarf in [local_rig.winter_scarf, ai_rig.winter_scarf,
			puppet_rig.winter_scarf]:
		if scarf.mesh.get_instance_id() != shared_mesh_id \
				or scarf.cast_shadow \
					!= GeometryInstance3D.SHADOW_CASTING_SETTING_OFF \
				or scarf.visibility_range_end <= 0.0 \
				or scarf.visibility_range_end > 64.0:
			return false
	return local_rig.winter_scarf.layers \
		== MonkeyRig.LOCAL_BODY_VISUAL_LAYER


func _chunk_instances_match(world: World, expected_ids: Dictionary) -> bool:
	if world.chunks.size() != expected_ids.size():
		return false
	for key in expected_ids:
		if not world.chunks.has(key):
			return false
		var chunk := world.chunks[key] as Chunk
		if not chunk or not is_instance_valid(chunk) \
				or chunk.get_instance_id() != int(expected_ids[key]):
			return false
	return true


func _weather_resources_match(system: SeasonalWeather,
		process_ids: Dictionary, mesh_ids: Dictionary) -> bool:
	if system._process_materials.size() != process_ids.size() \
			or system._particle_meshes.size() != mesh_ids.size() \
			or process_ids.size() > 3:
		return false
	for weather_kind in process_ids:
		if not system._process_materials.has(weather_kind) \
				or not system._particle_meshes.has(weather_kind) \
				or system._process_materials[weather_kind].get_instance_id() \
					!= int(process_ids[weather_kind]) \
				or system._particle_meshes[weather_kind].get_instance_id() \
					!= int(mesh_ids[weather_kind]):
			return false
	return true


func _count_shadow_directionals(node: Node) -> int:
	var count := 0
	for child in node.get_children():
		if child is DirectionalLight3D \
				and (child as DirectionalLight3D).shadow_enabled:
			count += 1
		count += _count_shadow_directionals(child)
	return count


func _is_midnight_blue(color: Color) -> bool:
	var luminance := color.get_luminance()
	return color.b > color.g * 1.5 and color.b > color.r * 2.0 \
		and luminance >= 0.015 and luminance <= 0.18


func _check(condition: bool, label: String) -> void:
	total += 1
	if condition:
		passed += 1
		print("  [ok] " + label)
	else:
		print("  [FAIL] " + label)


func _finish() -> void:
	print("SEASONTEST %d/%d %s" % [passed, total,
		"PASS" if passed == total else "FAIL"])
	get_tree().quit(0 if passed == total else 1)
