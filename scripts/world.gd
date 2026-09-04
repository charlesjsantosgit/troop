class_name World
extends Node3D
## Owns the streamed infinite jungle plus lighting, ambience, players/puppets.

const HorizonChunkScript = preload("res://scripts/horizon_chunk.gd")
const SkylineChunkScript = preload("res://scripts/skyline_chunk.gd")
const StratosChunkScript = preload("res://scripts/stratos_chunk.gd")
const FriendlyMonkeyScript = preload("res://scripts/friendly_monkey.gd")

signal combat_score_changed
signal villager_trade_requested(villager: Node3D, player: Node3D)
signal headshot_scored(source: Node3D, target: Node3D, lethal: bool, distance: float)

const STREAM_SHELL_BUDGET_USEC := 2400
const STREAM_SAFETY_BUDGET_USEC := 1400
const STREAM_DECORATION_BUDGET_USEC := 1400
const STREAM_SHELL_MAX_OPS := 3
const STREAM_SAFETY_MAX_OPS := 3
const STREAM_DECORATION_MAX_OPS := 3
const STRATOS_TERRAIN_ROW_BUDGET := 2
const STRATOS_PREFLIGHT_ROW_BUDGET := 6
const HORIZON_TREE_SOURCE_BUDGET := 4
const SKYLINE_TREE_SOURCE_BUDGET := 16
const HORIZON_TREE_SOURCE_BUDGET_FAST := 8
const SKYLINE_TREE_SOURCE_BUDGET_FAST := 32
const NEAR_PREDICTION_TIME := 0.85
const NEAR_PREDICTION_MAX_CHUNKS := 8.0
const STREAM_FAST_SPEED := 180.0
const TERRAIN_PROBE_MAX_AGE_USEC := 80000
const TERRAIN_PROBE_MAX_TRAVEL := Gen.CHUNK * 0.5
const TERRAIN_PROBE_VELOCITY_DELTA := 18.0
const TERRAIN_PROBE_SPACING := Gen.CHUNK * 2.0
const TERRAIN_PROBE_MAX_SAMPLES := 24
const HORIZON_PREDICTION_TIME := 1.4
const HORIZON_PREDICTION_MAX_SECTORS := 3
const GROUND_COLLISION_ALTITUDE_MARGIN := 18.0
const DESCENT_COLLISION_LOOKAHEAD := 3.0
const GROUND_ACTOR_COLLISION_RANGE_CHUNKS := Gen.VIEW_R + 2
const GROUND_ACTOR_COLLISION_PATCH_RADIUS := 1
# Every tracked actor is range-gated to the local player's surrounding chunk
# square before its 3x3 floor patch is added. This fixed ceiling keeps remote/AI
# collision shells from turning the near-stream queue into an unbounded lane.
const GROUND_ACTOR_COLLISION_SHELL_RADIUS := \
	GROUND_ACTOR_COLLISION_RANGE_CHUNKS + GROUND_ACTOR_COLLISION_PATCH_RADIUS
const GROUND_ACTOR_COLLISION_SHELL_TARGET_LIMIT := \
	(GROUND_ACTOR_COLLISION_SHELL_RADIUS * 2 + 1) \
	* (GROUND_ACTOR_COLLISION_SHELL_RADIUS * 2 + 1)
const STRATOS_PREDICTION_TIME := 2.0
const STRATOS_TARGET_REFRESH_DISTANCE := Gen.CHUNK * 2.0
const STRATOS_RADIUS_REFRESH_DISTANCE := Gen.CHUNK
## Literal chunk/horizon foliage is no longer useful once its longest 220 m
## visibility range sits well below the camera. Hysteresis prevents a hovering
## aircraft from repeatedly waking and suspending the detail queues, while the
## descent lookahead below wakes them several seconds before landing.
const LITERAL_DETAIL_SUSPEND_CLEARANCE := 260.0
const LITERAL_DETAIL_RESUME_CLEARANCE := 210.0
## Collapse each outgoing tier before vertical camera distance reaches that
## tier's hard visibility end, leaving the dithered successor already resident.
# These vertical thresholds are intentionally below each GeometryInstance's 3D
# visibility end. That leaves enough diagonal distance for the outgoing tier to
# reach its complete horizontal fade before the successor takes over.
const HORIZON_FOLIAGE_SUSPEND_CLEARANCE := 480.0
const HORIZON_FOLIAGE_RESUME_CLEARANCE := 400.0
const SKYLINE_FOLIAGE_SUSPEND_CLEARANCE := 1760.0
const SKYLINE_FOLIAGE_RESUME_CLEARANCE := 1560.0
## The original linear 300:1 altitude curve reached the complete 15-mile ring
## at only ~83 m. Preserve the authored 15-mile summit view, but grow toward it
## over the complete 6 km elevation range instead of on an ordinary hill.
const VIEW_ALTITUDE_FLOOR := 10.0
## Once horizon/skyline geometry is vertically out of range, its successor owns
## the complete under-aircraft view. No 48 m ground patch needs to chase a jet
## six kilometres overhead merely to fill a horizontal shader fade.
const FLIGHT_TERRAIN_NEAR_FADE := 0.0
const STREAMED_WILDERNESS_VEHICLE_LIMIT := 16
const VEHICLE_ENTRY_TIMEOUT_MS := 5000
const STREAM_DETAIL_ENQUEUED_META := &"stream_detail_enqueued_usec"
const DEFEAT_VIEW_TIME := 2.35
const MELEE_RADIUS := 0.88
const MELEE_DAMAGE := [24.0, 29.0, 38.0]
const MELEE_PRIMED_DAMAGE_MULTIPLIER := 1.5
const LIGHTING_UPDATE_STEP := 0.05
const SKY_UPDATE_STEP := 0.50
const CLOCK_RESYNC_STEP := 1.0
const CALENDAR_CHECK_STEP := 60.0
const MOON_SKY_ENERGY := 3.8
enum BuildStage {
	NOT_STARTED,
	SHARED_RESOURCES,
	ENVIRONMENT,
	WATER,
	LIGHTS,
	MARKER,
	PARTICLES,
	VEHICLES,
	COMPLETE,
}
const BUILD_STAGE_LABELS := [
	"not_started", "shared_resources", "environment", "water", "lights",
	"marker", "particles", "vehicles", "complete",
]

static var _muzzle_mesh: SphereMesh
static var _muzzle_material: StandardMaterial3D
static var _impact_mesh: SphereMesh
static var _impact_world_material: StandardMaterial3D
static var _impact_actor_material: StandardMaterial3D

var chunks: Dictionary = {}          # Vector2i -> Chunk
var _queue: Array = []
var _near_pending: Dictionary = {}
var _near_targets: Dictionary = {}
var _near_enqueued_at: Dictionary = {}
var _collision_targets: Dictionary = {}
var _collision_queue: Array[Chunk] = []
var _chunk_detail_queue: Array[Chunk] = []
var horizon_chunks: Dictionary = {}  # Vector2i -> HorizonChunk macro sectors
var _horizon_queue: Array = []
var _horizon_pending: Dictionary = {}
var _horizon_targets: Dictionary = {}
var _horizon_enqueued_at: Dictionary = {}
var _horizon_detail_queue: Array[HorizonChunk] = []
var skyline_chunks: Dictionary = {}  # Vector2i -> SkylineChunk mountain vista
var _skyline_queue: Array = []
var _skyline_pending: Dictionary = {}
var _skyline_enqueued_at: Dictionary = {}
var _skyline_detail_queue: Array[SkylineChunk] = []
var _skyline_center := Vector2i(0x3fffffff, 0x3fffffff)
var stratos_chunks: Dictionary = {}  # Vector2i -> StratosChunk (altitude tier)
var _stratos_queue: Array = []
var _stratos_enqueued_at: Dictionary = {}
var _stratos_targets: Dictionary = {}
var _stratos_required_targets: Dictionary = {}
var _active_stratos_sector: StratosChunk
var _active_stratos_key := Vector2i(0x3fffffff, 0x3fffffff)
var _active_stratos_started_usec := 0
var _stratos_center := Vector2i(0x3fffffff, 0x3fffffff)
var _stratos_prefetch_center := Vector2i(0x3fffffff, 0x3fffffff)
var _stratos_ring := -1
var _stratos_target_focus := Vector2(INF, INF)
var _stratos_prefetch_focus := Vector2(INF, INF)
var _stratos_target_radius := -1.0
var current_view_distance := Gen.VIEW_BASE_DISTANCE
## A return voyage prepares its physical landing site without streaming around
## a cabin that is thousands of metres above a different dimension.
var _expedition_stream_focus := Vector3(INF, INF, INF)
var _altitude_quality_low := false
var _stream_center := Vector2i(0x3fffffff, 0x3fffffff)
var _prefetch_center := Vector2i(0x3fffffff, 0x3fffffff)
var _near_guard_radius_state := -99
var _horizon_center := Vector2i(0x3fffffff, 0x3fffffff)
var _horizon_prefetch_center := Vector2i(0x3fffffff, 0x3fffffff)
var _far_shell_lane := 0
var _far_shell_defer_frames := 0
var _far_tree_lane := 0
var _decoration_lane := 0
var _stream_speed_mps := 0.0
var _ground_collision_required := true
var _local_collision_required := true
var _local_ground_clearance := 0.0
var _terrain_probe_position := Vector3(INF, INF, INF)
var _terrain_probe_velocity := Vector3.ZERO
var _terrain_probe_ground := 0.0
var _terrain_probe_collision_clearance := -INF
var _terrain_probe_detail_clearance := -INF
var _terrain_probe_usec := 0
var _literal_detail_suppressed := false
var _horizon_foliage_suppressed := false
var _skyline_foliage_suppressed := false
var _horizon_handoff_ready := true
var _skyline_handoff_ready := true
var _ground_actor_collision_centers: Array[Vector2i] = []
var _actor_collision_targets: Dictionary = {}
var _tracked_ground_vehicle_count := 0
var _stream_shell_usec_last := 0
var _stream_safety_usec_last := 0
var _stream_decoration_usec_last := 0
var _stream_shell_ops_last := 0
var _stream_safety_ops_last := 0
var _stream_decoration_ops_last := 0
var _stream_shells_built := 0
var _stream_cancelled_jobs := 0
var local_player: MonkeyPlayer
var expedition_manager: ExpeditionManager
var frontier: Node
var puppets: Dictionary = {}         # peer id -> Puppet
var vehicles: Dictionary = {}        # stable vehicle id -> Vehicle node
var _pending_vehicle_entry := ""     # vid awaiting the host's seat claim
var _pending_vehicle_entry_started_msec := 0
var _pending_vehicle_entry_request_id := 0
var _spawned_vehicle_ids: Dictionary = {}  # dedupe for currently retained spawns
var _streamed_vehicle_sources: Dictionary = {} # wilderness id -> origin chunk
var _retained_wilderness_vehicle_ids: Dictionary = {} # mounted once -> session citizen
var _marker: MeshInstance3D
var _particles: GPUParticles3D
var water_fx: WaterFX
# The compact Earth aviation chart ends below the separate lunar realm at 36 km.
# This is a game-scale optical transition, not Earth's real Karman altitude.
const SPACE_SKY_START_ALTITUDE := 12000.0
const SPACE_SKY_FULL_ALTITUDE := 30000.0
var _ground_sky: Sky
var _space_sky: Sky
var _photographic_space: LunarSky
var _space_sky_weight := 0.0
var _ground_fog_enabled := true
var _environment: Environment
var _sky_material: ShaderMaterial
var _celestial_sky: CelestialSky
var _sun: DirectionalLight3D
var _moon: DirectionalLight3D
var _moon_visual_strength := 0.0
var seasonal_weather: SeasonalWeather
var season := SeasonalCycle.Season.SUMMER
var weather := SeasonalCycle.Weather.CLEAR
var time_of_day_hours := 12.0
var daylight_amount := 1.0
var _lighting_update_timer := 0.0
var _sky_update_timer := 0.0
var _clock_resync_timer := CLOCK_RESYNC_STEP
var _calendar_check_timer := CALENDAR_CHECK_STEP
var _season_override_active := false
var _time_override_hour := -1.0
var _time_override_elapsed := 0.0
var _high_effects := false
var _fullscreen_performance := false
var _banana_nodes: Dictionary = {}   # banana id -> Banana (for network hide)
var supply_huts: Dictionary = {}     # stable hut id -> currently streamed SupplyHut
var opened_supply_huts: Dictionary = {} # stable hut id -> claimant/true, survives streaming
var _pending_supply_loot: Dictionary = {} # requested hut id -> immutable loot payload
var _rewarded_supply_huts: Dictionary = {} # local inventory idempotency guard
var _vine_sims: Dictionary = {}      # vine id -> released VinePhysics
var ai_opponent: Node3D
var friendly_monkeys: Array[Node3D] = []
var villagers: Array[Node3D] = []
var _friendly_serial := 0
var combat_kills: Dictionary = {}
var practice_targets: Array[PracticeTarget] = []
var _t := 0.0
var _biome_sample_timer := 0.0
var _biome_fog_target := Color(0.43, 0.61, 0.43)
var _biome_density_target := 0.0017
var _biome_saturation_target := 1.0
var _earth_streaming_enabled := true
var _earth_transit_surface_visible := true
var _earth_transit_light_weight := 1.0
var _sun_daylight_energy := 1.34
var _moon_daylight_energy := 0.14
var _lunar_shadow_quality_active := false
var _earth_shadow_filter_quality := 2
var _build_stage := BuildStage.NOT_STARTED
var _build_last_step_usec := 0
var _build_vehicle_definitions: Dictionary = {}
var _build_vehicle_queue: Array[String] = []
var _build_vehicle_cursor := 0
var _network_transient_effects_enabled := true


## Bounded altitude-to-horizon curve used by runtime streaming. The square root
## keeps useful aerial vistas at moderate elevation while ensuring only the
## planet's 6 km summit reaches the complete 15-mile tier.
static func stream_view_distance_for_altitude(altitude: float) -> float:
	var altitude_range := maxf(Gen.PLANET_SUMMIT_ELEVATION
		- VIEW_ALTITUDE_FLOOR, 1.0)
	var elevation_fraction := clampf((altitude - VIEW_ALTITUDE_FLOOR)
		/ altitude_range, 0.0, 1.0)
	return lerpf(Gen.VIEW_BASE_DISTANCE, Gen.VIEW_PEAK_DISTANCE,
		sqrt(elevation_fraction))


static func literal_detail_should_be_suppressed(clearance: float,
		currently_suppressed: bool) -> bool:
	return clearance > (LITERAL_DETAIL_RESUME_CLEARANCE
		if currently_suppressed else LITERAL_DETAIL_SUSPEND_CLEARANCE)


## True when a square stratos sector intersects a horizontal view circle. This
## keeps the camera's complete radial horizon while discarding square-ring
## corners that can never enter the far plane.
static func stratos_sector_intersects_circle(sector_key: Vector2i,
		focus_xz: Vector2, radius: float) -> bool:
	var sector_size := Gen.CHUNK * Gen.STRATOS_SECTOR_CHUNKS
	var minimum := Vector2(float(sector_key.x), float(sector_key.y)) * sector_size
	var maximum := minimum + Vector2.ONE * sector_size
	var nearest := Vector2(clampf(focus_xz.x, minimum.x, maximum.x),
		clampf(focus_xz.y, minimum.y, maximum.y))
	return nearest.distance_squared_to(focus_xz) <= radius * radius


static func circular_stratos_targets(focus_xz: Vector2, radius: float) -> Dictionary:
	var targets := {}
	var sector_size := Gen.CHUNK * Gen.STRATOS_SECTOR_CHUNKS
	var center := Vector2i(floori(focus_xz.x / sector_size),
		floori(focus_xz.y / sector_size))
	# One extra candidate row is needed when the focus is close to a sector edge.
	var candidate_ring := ceili(maxf(radius, 0.0) / sector_size) + 1
	for dx in range(-candidate_ring, candidate_ring + 1):
		for dz in range(-candidate_ring, candidate_ring + 1):
			var key := center + Vector2i(dx, dz)
			if stratos_sector_intersects_circle(key, focus_xz, radius):
				targets[key] = true
	return targets


## Conservative proof that the currently loaded sector set reaches the shader's
## live circular edge. Sampling multiple radial directions catches a focus that
## has moved into a sector not represented by the last target refresh; returning
## one full sector short makes the benchmark margin explicitly negative.
static func loaded_stratos_edge_coverage(loaded: Dictionary, focus_xz: Vector2,
		radius: float, direction_count := 16) -> float:
	if radius <= 0.0:
		return 0.0
	var sector_size := Gen.CHUNK * Gen.STRATOS_SECTOR_CHUNKS
	var edge_radius := maxf(radius - 1.0, 0.0)
	for direction_index in range(maxi(direction_count, 4)):
		var angle := TAU * float(direction_index) \
			/ float(maxi(direction_count, 4))
		var edge := focus_xz + Vector2(cos(angle), sin(angle)) * edge_radius
		var edge_key := Vector2i(floori(edge.x / sector_size),
			floori(edge.y / sector_size))
		if not loaded.has(edge_key):
			return maxf(radius - sector_size, 0.0)
	return radius


## Preserve the original synchronous API for solo play and deterministic tests.
## Online entry uses begin_build()/build_step() while its loading UI renders.
func build() -> void:
	begin_build()
	while not build_step():
		pass


## Begin a staged world build without allocating any renderer-heavy resources.
## The authoritative vehicle snapshot is copied into a de-duplicated queue, and
## its live registration signal is connected first so definitions arriving
## while the loading screen advances cannot fall into the snapshot/signal gap.
func begin_build() -> void:
	if _build_stage != BuildStage.NOT_STARTED:
		return
	_build_stage = BuildStage.SHARED_RESOURCES
	opened_supply_huts = Net.claimed_supply_chests.duplicate()
	if not Net.vehicle_spawn_registered.is_connected(
			_on_vehicle_spawn_registered):
		Net.vehicle_spawn_registered.connect(_on_vehicle_spawn_registered)
	# Vehicles restored early in the queue must still receive seat/rest changes
	# while later vehicles are loading. For queued vehicles these handlers are
	# harmless; spawn_vehicle() reads their latest authoritative state instead.
	if not Net.vehicle_claimed.is_connected(_on_vehicle_claimed):
		Net.vehicle_claimed.connect(_on_vehicle_claimed)
	if not Net.vehicle_released.is_connected(_on_vehicle_released):
		Net.vehicle_released.connect(_on_vehicle_released)
	if not Net.vehicle_request_finished.is_connected(_on_vehicle_request_finished):
		Net.vehicle_request_finished.connect(_on_vehicle_request_finished)
	for vehicle_id in Net.vehicle_spawn_definitions:
		var definition: Dictionary = Net.vehicle_spawn_definitions[vehicle_id]
		_queue_build_vehicle(str(vehicle_id), int(definition.get("kind", -1)),
			definition.get("pos", Vector3.ZERO),
			float(definition.get("yaw", 0.0)))


## Execute one coherent construction stage. Vehicle restoration is additionally
## bounded to one authoritative vehicle per call. Returns true only after every
## stage and every vehicle that arrived during construction has completed.
func build_step() -> bool:
	if _build_stage == BuildStage.NOT_STARTED:
		begin_build()
	if _build_stage == BuildStage.COMPLETE:
		_build_last_step_usec = 0
		return true
	var started := Time.get_ticks_usec()
	match _build_stage:
		BuildStage.SHARED_RESOURCES:
			_build_shared_resources()
			_build_stage = BuildStage.ENVIRONMENT
		BuildStage.ENVIRONMENT:
			_build_environment()
			_build_stage = BuildStage.WATER
		BuildStage.WATER:
			if _build_water():
				_build_stage = BuildStage.LIGHTS
		BuildStage.LIGHTS:
			_build_lights()
			_build_stage = BuildStage.MARKER
		BuildStage.MARKER:
			_build_marker()
			_build_stage = BuildStage.PARTICLES
		BuildStage.PARTICLES:
			_build_particles()
			_build_stage = BuildStage.VEHICLES
		BuildStage.VEHICLES:
			_restore_one_build_vehicle()
			if _build_vehicle_queue.is_empty():
				_finish_build()
	_build_last_step_usec = Time.get_ticks_usec() - started
	return _build_stage == BuildStage.COMPLETE


func is_build_complete() -> bool:
	return _build_stage == BuildStage.COMPLETE


func build_stage_name() -> String:
	if _build_stage == BuildStage.WATER and water_fx:
		return "water_" + water_fx.setup_stage_name()
	return BUILD_STAGE_LABELS[clampi(_build_stage, 0,
		BUILD_STAGE_LABELS.size() - 1)]


func build_progress() -> float:
	return float(_build_stage) / float(BuildStage.COMPLETE)


func build_last_step_usec() -> int:
	return _build_last_step_usec


func _build_shared_resources() -> void:
	Visuals.reset_terrain_residency()
	RenderingServer.directional_shadow_atlas_set_size(2048, true)
	_prepare_combat_fx()
	BananaBullet.prepare_resources()
	_apply_season(SeasonalCycle.season_from_system())
	# Visuals caches shared materials across World instances and test fixtures.
	# Re-establish ground-level handoffs explicitly so a previous aircraft world
	# cannot leave a new session's static materials collapsed to the flight shell.
	Visuals.set_altitude_lod_handoffs(Gen.SKYLINE_NEAR_FADE,
		Gen.STRATOS_NEAR_FADE)
	Visuals.set_stratos_view_radius(current_view_distance)
	time_of_day_hours = Net.authoritative_cycle_hour()


func _build_water() -> bool:
	if water_fx == null:
		water_fx = WaterFX.new()
		water_fx.name = "WaterFX"
		water_fx.begin_setup(Gen.WATER_Y)
		add_child(water_fx)
	return water_fx.setup_step()


func _build_environment() -> void:
	var phase_started := Time.get_ticks_usec()
	var env := Environment.new()
	_environment = env
	_celestial_sky = CelestialSky.new()
	_trace_environment_phase("celestial_resources", phase_started)
	phase_started = Time.get_ticks_usec()
	var sky_mat := _celestial_sky.get_material()
	_sky_material = sky_mat
	var sky := Sky.new()
	sky.sky_material = sky_mat
	sky.process_mode = Sky.PROCESS_MODE_INCREMENTAL
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	_ground_sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.44
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_exposure = 0.92
	env.glow_enabled = true
	env.glow_intensity = 0.38
	env.glow_strength = 0.62
	env.glow_bloom = 0.06
	env.ssao_enabled = true
	env.ssao_radius = 1.35
	env.ssao_intensity = 1.48
	env.ssao_power = 1.3
	# SSAO supplies the important canopy depth. SSIL and volumetrics cost much
	# more on an integrated GPU, so the performance tier leaves them optional.
	env.ssil_enabled = false
	env.ssil_radius = 3.5
	env.ssil_intensity = 0.65
	env.fog_enabled = true
	env.fog_light_color = Color(0.43, 0.61, 0.43)
	env.fog_density = 0.00100
	env.fog_height = 2.0
	# Keep the humid horizon without painting the playable forest floor the fog
	# colour. The former dense two-metre layer erased all albedo detail below the
	# canopy, even within a few metres of the camera.
	env.fog_height_density = 0.024
	env.fog_sky_affect = 0.12
	env.fog_aerial_perspective = 0.55
	env.volumetric_fog_enabled = false
	env.volumetric_fog_density = 0.0035
	env.volumetric_fog_albedo = Color(0.60, 0.75, 0.56)
	env.volumetric_fog_emission = Color(0.01, 0.015, 0.008)
	env.volumetric_fog_emission_energy = 0.04
	env.volumetric_fog_length = 78.0
	env.volumetric_fog_ambient_inject = 0.48
	env.adjustment_enabled = true
	env.adjustment_brightness = 0.96
	env.adjustment_contrast = 1.13
	env.adjustment_saturation = 1.0
	_trace_environment_phase("environment_settings", phase_started)
	phase_started = Time.get_ticks_usec()
	Visuals.stratos_ground_material()
	_trace_environment_phase("stratos_material", phase_started)
	phase_started = Time.get_ticks_usec()
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	_trace_environment_phase("environment_attach", phase_started)


func _trace_environment_phase(phase: String, started: int) -> void:
	if OS.get_environment("TROOP_JOIN_PROFILE") == "1":
		print("JOIN_ENV_PHASE %s ms=%.3f" % [phase,
			float(Time.get_ticks_usec() - started) / 1000.0])


func _build_lights() -> void:
	var sun := DirectionalLight3D.new()
	_sun = sun
	sun.rotation_degrees = Vector3(-40, -34, 0)
	sun.light_color = Color(1.0, 0.91, 0.70)
	sun.light_energy = 1.34
	sun.light_angular_distance = 0.62
	sun.sky_mode = DirectionalLight3D.SKY_MODE_LIGHT_AND_SKY
	sun.shadow_enabled = true
	sun.shadow_blur = 1.6
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	sun.directional_shadow_max_distance = 70.0
	sun.directional_shadow_fade_start = 0.72
	add_child(sun)

	# Moonlight gets a separate colour/intensity curve but deliberately has no
	# shadow pass. The sun remains the only shadow-casting directional light.
	var moon := DirectionalLight3D.new()
	_moon = moon
	moon.name = "Moon"
	moon.light_color = Color(0.42, 0.56, 0.88)
	moon.light_energy = 0.14
	moon.light_angular_distance = 0.52
	# The scene-light job remains separate from the visible cratered moon drawn by
	# CelestialSky, so the sky can be vivid without over-lighting the jungle.
	moon.sky_mode = DirectionalLight3D.SKY_MODE_LIGHT_ONLY
	moon.shadow_enabled = false
	add_child(moon)
	_apply_day_night(true)


func _build_marker() -> void:
	var mk_mat := StandardMaterial3D.new()
	mk_mat.albedo_color = Color(0.75, 1.0, 0.35, 0.9)
	mk_mat.emission_enabled = true
	mk_mat.emission = Color(0.55, 0.95, 0.22)
	mk_mat.emission_energy_multiplier = 1.8
	mk_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mk_mat.no_depth_test = true
	mk_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_marker = MeshInstance3D.new()
	var ms := TorusMesh.new()
	ms.inner_radius = 0.5
	ms.outer_radius = 0.64
	_marker.mesh = ms
	_marker.material_override = mk_mat
	_marker.visible = false
	add_child(_marker)


func _build_particles() -> void:
	_particles = GPUParticles3D.new()
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(28, 12, 28)
	pm.gravity = Vector3(0, -0.05, 0)
	pm.initial_velocity_min = 0.1
	pm.initial_velocity_max = 0.4
	pm.scale_min = 0.4
	pm.scale_max = 1.0
	var pmat := StandardMaterial3D.new()
	pmat.albedo_color = Color(1.0, 0.95, 0.6, 0.7)
	pmat.emission_enabled = true
	pmat.emission = Color(0.9, 0.85, 0.4)
	pmat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	pmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	pmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var quad := QuadMesh.new()
	quad.size = Vector2(0.045, 0.045)
	quad.material = pmat
	_particles.process_material = pm
	_particles.draw_pass_1 = quad
	_particles.amount = 120
	_particles.lifetime = 7.0
	_particles.local_coords = false
	_particles.fixed_fps = 20
	_particles.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_particles)


func _finish_build() -> void:
	# Refresh the authoritative chest snapshot after the staged window so a
	# claim delivered between begin_build() and runtime signal connection is not
	# lost. Chunks have not streamed yet, so there is no live hut to reconcile.
	opened_supply_huts = Net.claimed_supply_chests.duplicate()
	_connect_runtime_signals()
	_build_stage = BuildStage.COMPLETE


func _connect_runtime_signals() -> void:
	var bindings := [
		[Net.banana_taken, _on_banana_taken],
		[Net.supply_chest_claimed, _on_supply_chest_claimed],
		[Net.vine_released, _on_vine_released],
		[Net.bullet_fired, _on_network_bullet],
		[Net.melee_swung, _on_network_melee],
		[Net.peer_defeated, _on_peer_defeated],
		[Net.vehicle_claimed, _on_vehicle_claimed],
		[Net.vehicle_released, _on_vehicle_released],
		[Net.vehicle_request_finished, _on_vehicle_request_finished],
		[Net.cycle_hour_changed, _on_shared_cycle_hour_changed],
	]
	for binding in bindings:
		var source: Signal = binding[0]
		var callback: Callable = binding[1]
		if not source.is_connected(callback):
			source.connect(callback)


## Online entry disables these short-lived presentations until gameplay starts.
## Discard events instead of replaying stale shots/deaths/vines when the paused
## build becomes active. Persistent claims and vehicle snapshots stay live, and
## ordinary gameplay pauses never implicitly change this explicit entry gate.
func set_network_transient_effects_enabled(enabled: bool) -> void:
	_network_transient_effects_enabled = enabled


func _queue_build_vehicle(vid: String, kind: int, pos: Vector3,
		yaw: float) -> void:
	if vid.is_empty() or kind < Vehicle.Kind.BIKE or kind > Vehicle.Kind.JET:
		return
	if vehicles.has(vid):
		return
	var already_queued := _build_vehicle_definitions.has(vid)
	_build_vehicle_definitions[vid] = {
		"kind": kind, "pos": pos, "yaw": yaw,
	}
	if not already_queued:
		_build_vehicle_queue.append(vid)


func _restore_one_build_vehicle() -> void:
	# Indexing rather than pop_front keeps queue bookkeeping constant-time even
	# for a large snapshot. Each call consumes at most one definition, including
	# stale entries, so an interrupted/replayed registration cannot add a spike.
	if _build_vehicle_cursor < _build_vehicle_queue.size():
		var vid: String = _build_vehicle_queue[_build_vehicle_cursor]
		_build_vehicle_cursor += 1
		var definition: Dictionary = _build_vehicle_definitions.get(vid, {})
		_build_vehicle_definitions.erase(vid)
		if not definition.is_empty() and not vehicles.has(vid):
			spawn_vehicle(int(definition.kind), vid, definition.get("pos", Vector3.ZERO),
				float(definition.get("yaw", 0.0)))
	if _build_vehicle_cursor >= _build_vehicle_queue.size():
		_build_vehicle_queue.clear()
		_build_vehicle_cursor = 0


func set_expensive_effects(enabled: bool) -> void:
	if _high_effects == enabled:
		return
	_high_effects = enabled
	_apply_effect_quality()


func set_fullscreen_performance(enabled: bool) -> void:
	if _fullscreen_performance == enabled:
		return
	_fullscreen_performance = enabled
	_apply_effect_quality()


func _apply_effect_quality() -> void:
	if not _environment:
		return
	# Preserve the core material/shadow look; only the costly screen-space and
	# volumetric layers step down when adaptive resolution is already working.
	_environment.ssao_enabled = not _fullscreen_performance
	_environment.ssil_enabled = _high_effects and not _fullscreen_performance
	_environment.volumetric_fog_enabled = _high_effects and not _fullscreen_performance
	if _sun:
		_sun.directional_shadow_max_distance = 58.0 if _fullscreen_performance \
			else (82.0 if _high_effects else 70.0)
	if _particles:
		_particles.amount = 80 if _fullscreen_performance else (180 if _high_effects else 120)
	if seasonal_weather:
		seasonal_weather.set_quality(_high_effects, _fullscreen_performance)
	if water_fx:
		water_fx.set_effect_quality(_high_effects, _fullscreen_performance)
	for vehicle_value in vehicles.values():
		if is_instance_valid(vehicle_value):
			(vehicle_value as Vehicle).set_effect_quality(_high_effects,
				_fullscreen_performance)


func set_season_override(next_season: SeasonalCycle.Season) -> void:
	_season_override_active = true
	_apply_season(next_season)


func clear_season_override() -> void:
	_season_override_active = false
	_apply_season(SeasonalCycle.season_from_system())


func set_time_of_day_override(hour: float) -> void:
	_time_override_hour = wrapf(hour, 0.0, 24.0)
	_time_override_elapsed = 0.0
	time_of_day_hours = _time_override_hour
	_apply_day_night(true)


func clear_time_of_day_override() -> void:
	_time_override_hour = -1.0
	_time_override_elapsed = 0.0
	_clock_resync_timer = CLOCK_RESYNC_STEP
	time_of_day_hours = Net.authoritative_cycle_hour()
	_apply_day_night(true)


## A live admin time change is a server clock re-anchor, not a local visual
## override. Clearing any local fixture override here keeps every connected sky
## on the same continuously advancing phase, including the issuing admin.
func _on_shared_cycle_hour_changed(hour: float) -> void:
	if not is_finite(hour):
		return
	_time_override_hour = -1.0
	_time_override_elapsed = 0.0
	_clock_resync_timer = CLOCK_RESYNC_STEP
	time_of_day_hours = wrapf(hour, 0.0, 24.0)
	_apply_day_night(true)


func moon_visual_strength() -> float:
	return _moon_visual_strength


func moon_source_direction() -> Vector3:
	if not _moon:
		return Vector3.UP
	return _moon.global_basis.z.normalized()


func _apply_season(next_season: SeasonalCycle.Season) -> void:
	season = next_season
	SeasonalCycle.active_season = next_season
	weather = SeasonalCycle.weather_for_season(next_season)
	Visuals.set_season(next_season)
	if seasonal_weather:
		seasonal_weather.set_weather(weather)
	_apply_scarf_state()
	if _environment and _sun:
		_apply_day_night(true)


func _ensure_seasonal_weather() -> void:
	if seasonal_weather or not local_player:
		return
	seasonal_weather = SeasonalWeather.new()
	seasonal_weather.name = "SeasonalWeather"
	add_child(seasonal_weather)
	seasonal_weather.setup(local_player, weather)
	seasonal_weather.set_quality(_high_effects, _fullscreen_performance)


func _apply_scarf_state() -> void:
	var winter := season == SeasonalCycle.Season.WINTER
	if local_player and is_instance_valid(local_player) and local_player.rig:
		local_player.rig.set_winter_scarf_visible(winter)
	if ai_opponent and is_instance_valid(ai_opponent) and ai_opponent is MonkeyPlayer \
			and (ai_opponent as MonkeyPlayer).rig:
		(ai_opponent as MonkeyPlayer).rig.set_winter_scarf_visible(winter)
	for puppet_value in puppets.values():
		var puppet := puppet_value as Puppet
		if puppet and is_instance_valid(puppet) and puppet.rig:
			puppet.rig.set_winter_scarf_visible(winter)
	if is_inside_tree():
		for ragdoll in get_tree().get_nodes_in_group("monkey_ragdolls"):
			if ragdoll.has_method("set_winter_scarf_visible"):
				ragdoll.call("set_winter_scarf_visible", winter)


func _on_banana_taken(id: String) -> void:
	if _banana_nodes.has(id):
		var b = _banana_nodes[id]
		if is_instance_valid(b):
			Sfx.play_at("banana", b.global_position, -4)
			b.queue_free()
		_banana_nodes.erase(id)


func register_banana(b: Banana) -> void:
	_banana_nodes[b.id] = b


func register_supply_hut(hut: SupplyHut) -> void:
	if not hut or hut.hut_id.is_empty():
		return
	supply_huts[hut.hut_id] = hut
	if opened_supply_huts.has(hut.hut_id):
		hut.set_opened(true, false)


func unregister_supply_hut(hut: SupplyHut) -> void:
	if not hut or hut.hut_id.is_empty():
		return
	# A deferred old chunk must never erase a newly streamed replacement with the
	# same deterministic ID.
	if supply_huts.get(hut.hut_id) == hut:
		supply_huts.erase(hut.hut_id)


func is_supply_hut_opened(hut_id: String) -> bool:
	return opened_supply_huts.has(hut_id)


## Nearest unopened supply chest within the hut's interaction radius. This is a
## direct registry lookup rather than a physics overlap, so outer-ring collision
## budgeting can never make an interactable flicker for one frame.
func _raw_nearby_supply_chest(player: Node3D) -> SupplyHut:
	if not player or not is_instance_valid(player):
		return null
	var nearest: SupplyHut
	var nearest_distance_sq := INF
	var stale_ids: Array = []
	for hut_id in supply_huts:
		var candidate = supply_huts[hut_id]
		if not is_instance_valid(candidate) or candidate.is_queued_for_deletion():
			stale_ids.append(hut_id)
			continue
		var hut := candidate as SupplyHut
		if not hut or hut.is_opened() or opened_supply_huts.has(hut.hut_id) \
				or _pending_supply_loot.has(hut.hut_id):
			continue
		var distance_sq := player.global_position.distance_squared_to(
			hut.chest_interaction_position())
		var interaction_distance := hut.interaction_range()
		if distance_sq <= interaction_distance * interaction_distance \
				and distance_sq < nearest_distance_sq:
			nearest = hut
			nearest_distance_sq = distance_sq
	for stale_id in stale_ids:
		supply_huts.erase(stale_id)
	return nearest


## Public HUD query. A chest deliberately keeps its established precedence
## over machines while its latch is within reach; try_physical_interaction()
## consumes that exact same target.
func nearby_supply_chest(player: Node3D) -> SupplyHut:
	if player is MonkeyPlayer and ((player as MonkeyPlayer).vehicle \
			or (player as MonkeyPlayer).expedition_locked):
		return null
	return _raw_nearby_supply_chest(player)


## Claim and animate the nearest chest. Solo play preserves the immediate path;
## multiplayer waits for the host's winning claim before mutating inventory.
func try_open_supply_chest(player: Node3D) -> bool:
	var hut := nearby_supply_chest(player)
	if not hut:
		return false
	return _open_supply_chest_target(player, hut)


func _open_supply_chest_target(player: Node3D, hut: SupplyHut) -> bool:
	if not is_instance_valid(hut) or hut.is_queued_for_deletion():
		return false
	if opened_supply_huts.has(hut.hut_id):
		hut.set_opened(true, false)
		return false
	if Net.active:
		_pending_supply_loot[hut.hut_id] = hut.loot_payload()
		if Net.request_supply_chest(hut.hut_id):
			return true
		_pending_supply_loot.erase(hut.hut_id)
		if Net.claimed_supply_chests.has(hut.hut_id):
			opened_supply_huts[hut.hut_id] = \
				int(Net.claimed_supply_chests[hut.hut_id])
			hut.set_opened(true, false)
		return false
	opened_supply_huts[hut.hut_id] = true
	hut.open_chest(true)
	_deliver_supply_payload(player, hut.loot_payload())
	return true


func try_expedition_interact(player: MonkeyPlayer) -> bool:
	if is_instance_valid(frontier) and frontier.try_interact(player):
		return true
	return expedition_manager != null \
		and is_instance_valid(expedition_manager) \
		and expedition_manager.try_non_rocket_interact(player)


func _on_supply_chest_claimed(hut_id: String, claimant_id: int) -> void:
	var payload: Dictionary = _pending_supply_loot.get(hut_id, {})
	_pending_supply_loot.erase(hut_id)
	opened_supply_huts[hut_id] = claimant_id

	var candidate = supply_huts.get(hut_id)
	if is_instance_valid(candidate) and not candidate.is_queued_for_deletion():
		(candidate as SupplyHut).open_chest(true)

	# Only the peer that requested and won has a pending payload. The explicit ID
	# check keeps inventory local even if stale state ever leaves such a payload.
	if claimant_id != Net.local_id() or payload.is_empty() \
			or _rewarded_supply_huts.has(hut_id):
		return
	_rewarded_supply_huts[hut_id] = true
	_deliver_supply_payload(local_player, payload)


func _deliver_supply_payload(player: Node3D, payload: Dictionary) -> void:
	if not is_instance_valid(player) or payload.is_empty():
		return
	if player.has_method("receive_supply_loot"):
		player.call("receive_supply_loot", int(payload.get("ammo_kind", 0)),
			int(payload.get("ammo_amount", 0)), int(payload.get("bandages", 0)))
	if player == local_player and bool(payload.get("normal_backpack", false)) \
			and expedition_manager and is_instance_valid(expedition_manager):
		expedition_manager.grant_normal_backpack()


# ---- vehicles --------------------------------------------------------------
# Vehicles are world-level nodes (never chunk children): a machine driven three
# kilometres from its spawn chunk must survive that chunk streaming out.

func spawn_vehicle(kind: int, vid: String, pos: Vector3,
		yaw := 0.0) -> Vehicle:
	if vehicles.has(vid):
		return vehicles[vid]
	var v: Vehicle
	match kind:
		Vehicle.Kind.BIKE:
			v = Motorcycle.new()
		Vehicle.Kind.BOAT:
			v = Airboat.new()
		Vehicle.Kind.JET:
			v = FighterJet.new()
		_:
			v = SafariJeep.new()
	v.setup(vid, self)
	add_child(v)
	v.set_effect_quality(_high_effects, _fullscreen_performance)
	v.settle_at(pos, yaw)
	vehicles[vid] = v
	# Late joiners: apply the host's resting transform and any live claim.
	if Net.vehicle_rests.has(vid):
		var rest: Array = Net.vehicle_rests[vid]
		if rest.size() == 4:
			v.apply_rest_state(rest[0], float(rest[1]), float(rest[2]),
				float(rest[3]))
	if Net.active and Net.claimed_vehicles.has(vid) \
			and int(Net.claimed_vehicles[vid]) != Net.local_id():
		v.set_remote_controlled(true, int(Net.claimed_vehicles[vid]))
	return v


## Chunk streaming hands deterministic spawn definitions up here. Retained,
## driven, curated, and networked IDs remain deduplicated for the session;
## untouched disposable wilderness IDs leave this set when their chunks retire,
## allowing the same deterministic machine to respawn if the player returns.
func request_vehicle_spawns(defs: Array) -> void:
	for def in defs:
		var vid := str(def.get("id", ""))
		if vid.is_empty() or _spawned_vehicle_ids.has(vid) \
				or vehicles.has(vid):
			continue
		var spawn_pos: Vector3 = def.get("pos", Vector3.ZERO)
		var source := Vector2i(floori(spawn_pos.x / Gen.CHUNK),
			floori(spawn_pos.z / Gen.CHUNK))
		# Only coordinate IDs are disposable wilderness finds. Curated pool/dock/
		# hangar machines and admin/network definitions remain session citizens.
		if vid == "v:%d,%d#0" % [source.x, source.y]:
			_streamed_vehicle_sources[vid] = source
		_spawned_vehicle_ids[vid] = true
		spawn_vehicle(int(def.get("kind", 0)), vid, spawn_pos,
			float(def.get("yaw", 0.0)))


## Once a player has successfully mounted a deterministic wilderness find, it is
## no longer disposable streaming scenery. Keep its stable ID and live node for
## the rest of this world session so dismounting preserves the parked transform.
func _mark_wilderness_vehicle_touched(vid: String) -> void:
	if _streamed_vehicle_sources.has(vid):
		_retained_wilderness_vehicle_ids[vid] = true


func _streamed_vehicle_is_protected(vid: String, vehicle: Vehicle) -> bool:
	return not is_instance_valid(vehicle) or vehicle.driver != null \
		or vehicle.remote_controlled or vehicle.occupied_by_peer != 0 \
		or _pending_vehicle_entry == vid or Net.claimed_vehicles.has(vid) \
		or Net.vehicle_rests.has(vid) \
		or Net.vehicle_spawn_definitions.has(vid) \
		or _retained_wilderness_vehicle_ids.has(vid)


func _retire_streamed_wilderness_vehicle(vid: String) -> void:
	var candidate = vehicles.get(vid)
	if is_instance_valid(candidate):
		(candidate as Vehicle).queue_free()
	vehicles.erase(vid)
	_streamed_vehicle_sources.erase(vid)
	_retained_wilderness_vehicle_ids.erase(vid)
	_spawned_vehicle_ids.erase(vid)


## Deterministic untouched wilderness finds follow their source/actual chunk and
## retire once both are outside the bounded near corridor. Driven, claimed, or
## replicated machines are explicitly retained, preserving the old promise that
## a player can take a vehicle kilometres from where it originally spawned.
func _retire_streamed_wilderness_vehicles() -> void:
	var disposable: Array[String] = []
	for vid_value in _streamed_vehicle_sources.keys():
		var vid := str(vid_value)
		var candidate = vehicles.get(vid)
		if not is_instance_valid(candidate):
			disposable.append(vid)
			continue
		var vehicle := candidate as Vehicle
		if _streamed_vehicle_is_protected(vid, vehicle):
			continue
		var source: Vector2i = _streamed_vehicle_sources[vid]
		var actual := Vector2i(floori(vehicle.global_position.x / Gen.CHUNK),
			floori(vehicle.global_position.z / Gen.CHUNK))
		if not _near_targets.has(source) and not _near_targets.has(actual):
			disposable.append(vid)
	for vid in disposable:
		_retire_streamed_wilderness_vehicle(vid)

	# The deterministic density normally leaves only 2-5 finds inside the swept
	# corridor. Keep a hard safety bound for pathological seeds by retiring the
	# farthest untouched machines first; protected player/network state is exempt.
	var unprotected: Array[Vehicle] = []
	for vid_value in _streamed_vehicle_sources.keys():
		var vid := str(vid_value)
		var candidate = vehicles.get(vid)
		if is_instance_valid(candidate) \
				and not _streamed_vehicle_is_protected(vid, candidate as Vehicle):
			unprotected.append(candidate as Vehicle)
	if unprotected.size() <= STREAMED_WILDERNESS_VEHICLE_LIMIT:
		return
	var focus := local_player.global_position if local_player else Vector3.ZERO
	unprotected.sort_custom(func(a: Vehicle, b: Vehicle):
		return a.global_position.distance_squared_to(focus) \
			> b.global_position.distance_squared_to(focus))
	while unprotected.size() > STREAMED_WILDERNESS_VEHICLE_LIMIT:
		var vehicle: Vehicle = unprotected.pop_front() as Vehicle
		_retire_streamed_wilderness_vehicle(vehicle.vid)


func vehicle_by_id(vid: String) -> Vehicle:
	var v = vehicles.get(vid)
	if is_instance_valid(v) and not v.is_queued_for_deletion():
		return v
	vehicles.erase(vid)
	return null


## Nearest enterable vehicle in arm's reach — a registry lookup like chests.
func _raw_nearby_vehicle(player: Node3D) -> Vehicle:
	if not player or not is_instance_valid(player):
		return null
	var nearest: Vehicle = null
	var nearest_distance_sq := INF
	var stale: Array = []
	for vid in vehicles:
		var candidate = vehicles[vid]
		if not is_instance_valid(candidate) \
				or candidate.is_queued_for_deletion():
			stale.append(vid)
			continue
		var v := candidate as Vehicle
		if not v or not v.can_enter(player):
			continue
		var distance_sq := player.global_position.distance_squared_to(
			v.interaction_position())
		if distance_sq <= Vehicle.ENTER_RANGE * Vehicle.ENTER_RANGE \
				and distance_sq < nearest_distance_sq:
			nearest = v
			nearest_distance_sq = distance_sq
	for vid in stale:
		vehicles.erase(vid)
	return nearest


## One entry selector shared by Player, HUD and interaction overlays. Supply
## chests retain their explicit HUD priority. Otherwise the closest real entry
## point wins between an ordinary vehicle seat and the rocket hatch.
func nearby_physical_interaction(player: Node3D) -> Dictionary:
	if not player or not is_instance_valid(player):
		return {}
	if player is MonkeyPlayer and ((player as MonkeyPlayer).vehicle \
			or (player as MonkeyPlayer).expedition_locked):
		return {}
	var hut := _raw_nearby_supply_chest(player)
	if hut:
		var latch := hut.chest_interaction_position()
		return {"kind": "supply_chest", "target": hut, "position": latch,
			"distance_squared": player.global_position.distance_squared_to(latch)}
	var nearest: Dictionary = {}
	var ride := _raw_nearby_vehicle(player)
	if ride:
		var seat := ride.interaction_position()
		nearest = {"kind": "vehicle", "target": ride, "position": seat,
			"distance_squared": player.global_position.distance_squared_to(seat)}
	if expedition_manager and is_instance_valid(expedition_manager) \
			and expedition_manager.has_method("rocket_interaction_candidate"):
		var rocket_candidate: Dictionary = expedition_manager.rocket_interaction_candidate(player)
		if not rocket_candidate.is_empty() and (nearest.is_empty() \
				or float(rocket_candidate.get("distance_squared", INF)) \
				< float(nearest.get("distance_squared", INF))):
			nearest = rocket_candidate
	return nearest


func nearby_vehicle(player: Node3D) -> Vehicle:
	var interaction := nearby_physical_interaction(player)
	return interaction.get("target") as Vehicle \
		if interaction.get("kind", "") == "vehicle" else null


## Dispatch the already selected physical target once. Even if an online claim
## loses a race on the host, the physical target still consumes this tap instead
## of unexpectedly opening a social menu behind it.
func try_physical_interaction(player: Node3D) -> bool:
	var interaction := nearby_physical_interaction(player)
	if interaction.is_empty():
		return false
	match str(interaction.get("kind", "")):
		"supply_chest":
			_open_supply_chest_target(player,
				interaction.get("target") as SupplyHut)
		"vehicle":
			_enter_vehicle_target(player, interaction.get("target") as Vehicle)
		"rocket":
			if expedition_manager and is_instance_valid(expedition_manager):
				expedition_manager.try_rocket_interact(player)
	return true


## Mount the nearest free vehicle. Solo mounts instantly; online asks the host
## for the seat claim and mounts when it is granted.
func try_enter_vehicle(player: Node3D) -> bool:
	var v := nearby_vehicle(player)
	if v == null or not player.has_method("enter_vehicle"):
		return false
	return _enter_vehicle_target(player, v)


func _enter_vehicle_target(player: Node3D, v: Vehicle) -> bool:
	if not is_instance_valid(v) or not v.can_enter(player) \
			or not player.has_method("enter_vehicle"):
		return false
	if not Net.active:
		player.call("enter_vehicle", v)
		if v.driver == player:
			_mark_wilderness_vehicle_touched(v.vid)
		return true
	if not _pending_vehicle_entry.is_empty():
		_vehicle_entry_notice("Waiting for the vehicle seat…")
		return true
	_pending_vehicle_entry = v.vid
	_pending_vehicle_entry_started_msec = Time.get_ticks_msec()
	_pending_vehicle_entry_request_id = _pending_vehicle_entry_request_id + 1 \
		if _pending_vehicle_entry_request_id < 2147483647 else 1
	_vehicle_entry_notice("Boarding %s…" % v.display_name())
	if Net.request_vehicle(v.vid, _pending_vehicle_entry_request_id):
		return true
	_pending_vehicle_entry = ""
	_vehicle_entry_notice("That seat is unavailable. Try another vehicle.")
	return false


func _vehicle_entry_notice(message: String) -> void:
	if is_instance_valid(local_player):
		local_player.supply_notice = message
		local_player.supply_notice_remaining = 3.0


func _vehicle_entry_still_wanted(v: Vehicle) -> bool:
	return is_instance_valid(local_player) and is_instance_valid(v) \
		and not local_player.defeated and not local_player.expedition_locked \
		and local_player.vehicle == null \
		and local_player.global_position.distance_squared_to(v.interaction_position()) \
			<= Vehicle.ENTER_RANGE * Vehicle.ENTER_RANGE


func _update_pending_vehicle_entry() -> void:
	if _pending_vehicle_entry.is_empty():
		return
	var v := vehicle_by_id(_pending_vehicle_entry)
	if not Net.active or not _vehicle_entry_still_wanted(v):
		_pending_vehicle_entry = ""
		return
	var elapsed := Time.get_ticks_msec() - _pending_vehicle_entry_started_msec
	if elapsed >= VEHICLE_ENTRY_TIMEOUT_MS:
		_pending_vehicle_entry = ""
		_vehicle_entry_notice("The seat request timed out. Check ping, then press E to retry.")


func _on_vehicle_claimed(vid: String, claimant_id: int) -> void:
	var v := vehicle_by_id(vid)
	if claimant_id == Net.local_id():
		var wanted := _pending_vehicle_entry == vid and _vehicle_entry_still_wanted(v) \
			and Time.get_ticks_msec() - _pending_vehicle_entry_started_msec < VEHICLE_ENTRY_TIMEOUT_MS
		if _pending_vehicle_entry == vid:
			_pending_vehicle_entry = ""
		if wanted:
			local_player.enter_vehicle(v)
			if v.driver == local_player:
				_mark_wilderness_vehicle_touched(v.vid)
		# A late grant must not teleport a player who walked away or leave a
		# vehicle permanently occupied by a request they no longer want.
		if not is_instance_valid(local_player) or local_player.vehicle != v or v == null:
			Net.release_vehicle(vid, [])
		return
	if _pending_vehicle_entry == vid:
		_pending_vehicle_entry = ""
		_vehicle_entry_notice("Another player took that seat. Try another vehicle.")
	if v:
		v.set_remote_controlled(true, claimant_id)


func _on_vehicle_request_finished(vid: String, accepted: bool, reason: String, request_id: int) -> void:
	if accepted or _pending_vehicle_entry != vid or request_id != _pending_vehicle_entry_request_id:
		return
	_pending_vehicle_entry = ""
	_vehicle_entry_notice(reason if not reason.is_empty() else "That seat is unavailable. Try again nearby.")


func _on_vehicle_spawn_registered(vid: String, kind: int, pos: Vector3,
		yaw: float) -> void:
	if _build_stage != BuildStage.NOT_STARTED and _build_stage != BuildStage.COMPLETE:
		_queue_build_vehicle(vid, kind, pos, yaw)
		return
	if kind >= Vehicle.Kind.BIKE and kind <= Vehicle.Kind.JET \
			and vehicle_by_id(vid) == null:
		spawn_vehicle(kind, vid, pos, yaw)


func _on_vehicle_released(vid: String, rest: Array) -> void:
	if _pending_vehicle_entry == vid:
		_pending_vehicle_entry = ""
	var v := vehicle_by_id(vid)
	if v == null:
		return
	if v.remote_controlled:
		v.set_remote_controlled(false)
	if rest.size() == 4 and v.driver == null:
		v.apply_rest_state(rest[0], float(rest[1]), float(rest[2]),
			float(rest[3]))


## Feed a remote driver's replicated state into the vehicle node, spawning it
## on demand if this peer has never streamed the vehicle's origin chunk.
func apply_remote_vehicle_state(peer_id: int, kind: int, vid: String,
		pos: Vector3, yaw: float, aux: Vector3, vel: Vector3) -> void:
	var v := vehicle_by_id(vid)
	if v == null:
		v = spawn_vehicle(kind, vid, pos, yaw)
	if v.driver != null:
		return   # never let remote state fight the local driver's seat
	if not v.remote_controlled or v.occupied_by_peer != peer_id:
		v.set_remote_controlled(true, peer_id)
	v.apply_remote_state(pos, yaw, aux, vel)


func spawn_local(peer_id: int, pname: String) -> MonkeyPlayer:
	var p := MonkeyPlayer.new()
	p.peer_id = peer_id
	p.display_name = pname
	p.is_local = true
	p.world = self
	p.position = spawn_position(peer_id)
	add_child(p)
	local_player = p
	combat_kills[peer_id] = 0
	_ensure_seasonal_weather()
	_apply_scarf_state()
	return p


func spawn_friendly(mode: int, at: Vector3, target: Node3D = null) -> Node3D:
	var friend = FriendlyMonkeyScript.new()
	_friendly_serial += 1
	friend.peer_id = -100 - _friendly_serial
	friend.display_name = ["Loop", "Shadow", "Steady", "Ookbar"][
		clampi(mode, 0, 3)]
	friend.is_local = false
	friend.is_ai = true
	friend.world = self
	friend.configure_friendly(mode, at, target)
	friend.position = at
	add_child(friend)
	friendly_monkeys.append(friend)
	if mode == FriendlyMonkeyScript.Mode.VILLAGER:
		villagers.append(friend)
	return friend


## E-interaction: a trading villager within reach outranks chests and vines.
func nearby_trade_villager(player: Node3D) -> Node3D:
	for villager in villagers:
		if is_instance_valid(villager) \
				and villager.global_position.distance_to(
					player.global_position) < 3.4:
			return villager
	return null


func try_open_villager_trade(player: Node3D) -> bool:
	var villager := nearby_trade_villager(player)
	if not villager:
		return false
	villager_trade_requested.emit(villager, player)
	return true


func spawn_solo_ai() -> Node3D:
	if ai_opponent and is_instance_valid(ai_opponent):
		return ai_opponent
	var bot = load("res://scripts/ai_monkey.gd").new()
	bot.peer_id = -1
	bot.display_name = "Captain Peel"
	bot.is_local = false
	bot.is_ai = true
	bot.world = self
	bot.target = local_player
	var x := 12.0
	var z := -14.0
	bot.position = Vector3(x, Gen.height(x, z) + 2.2, z)
	add_child(bot)
	ai_opponent = bot
	combat_kills[-1] = 0
	_apply_scarf_state()
	return bot


func spawn_practice_targets() -> void:
	if not practice_targets.is_empty():
		return
	for flat_pos in [Vector2(-9, -15), Vector2(1, -22), Vector2(11, -17)]:
		var target := PracticeTarget.new()
		add_child(target)
		var pos := Vector3(flat_pos.x, Gen.height(flat_pos.x, flat_pos.y), flat_pos.y)
		target.setup(pos, spawn_point() + Vector3.UP)
		practice_targets.append(target)


func spawn_puppet(peer_id: int, pname: String) -> Puppet:
	var pu := Puppet.new()
	pu.setup(peer_id, pname)
	add_child(pu)
	puppets[peer_id] = pu
	_apply_scarf_state()
	return pu


func remove_puppet(peer_id: int) -> void:
	if puppets.has(peer_id):
		if is_instance_valid(puppets[peer_id]):
			puppets[peer_id].queue_free()
		puppets.erase(peer_id)


func _on_peer_defeated(peer_id: int, pos: Vector3, yaw: float,
		death_velocity: Vector3, impulse: Vector3, headshot: bool) -> void:
	if not _network_transient_effects_enabled:
		return
	if puppets.has(peer_id) and is_instance_valid(puppets[peer_id]):
		puppets[peer_id].begin_defeat(pos, yaw, death_velocity, impulse,
			headshot)


func claim_vine(id: String) -> void:
	if _vine_sims.has(id):
		var sim: VinePhysics = _vine_sims[id]
		_vine_sims.erase(id)
		if is_instance_valid(sim):
			sim.cancel()


func _on_vine_released(id: String, hand: Vector3, release_velocity: Vector3,
		length: float, shape: PackedVector3Array) -> void:
	if not _network_transient_effects_enabled:
		return
	if not Gen.vines.has(id):
		return
	claim_vine(id)
	var vine: Dictionary = Gen.vines[id]
	var sim := VinePhysics.new()
	add_child(sim)
	sim.finished.connect(_on_vine_sim_finished)
	_vine_sims[id] = sim
	sim.setup(id, vine.anchor, length, shape, release_velocity)


func _on_vine_sim_finished(id: String, simulation: VinePhysics) -> void:
	if _vine_sims.get(id) == simulation:
		_vine_sims.erase(id)


func spawn_point() -> Vector3:
	return Vector3(0, Gen.height(0, 0) + 2.5, 0)


## Deterministic per-peer spawn spot: a small ID-derived jitter keeps
## simultaneous joiners from stacking inside each other.
func spawn_position(peer_id: int) -> Vector3:
	var jitter := Vector3(float(peer_id % 5) - 2.0, 0,
		float((peer_id / 5) % 5) - 2.0)
	return spawn_point() + jitter


func respawn(p: MonkeyPlayer) -> void:
	if p.state == p.S.SWING:
		p._release(false)
	if p == local_player and expedition_manager \
			and is_instance_valid(expedition_manager) \
			and expedition_manager.rescue_local_player_from_lunar_void(p):
		return
	var pos := p.global_position
	p.global_position = Vector3(pos.x, Gen.height(pos.x, pos.z) + 3.0, pos.z)
	p.reset_physics_interpolation()
	p.velocity = Vector3.ZERO


func void_rescue_height(p: MonkeyPlayer) -> float:
	if p == local_player and expedition_manager \
			and is_instance_valid(expedition_manager):
		return expedition_manager.lunar_void_rescue_height(p)
	return -25.0


# ---- banana revolver combat ------------------------------------------------

func spawn_bullet(shooter: Node3D, origin: Vector3, initial_velocity: Vector3,
		damage := BananaBullet.DAMAGE, headshot_rule := true,
		weapon_kind := Net.WEAPON_REVOLVER) -> void:
	var bullet := BananaBullet.new()
	add_child(bullet)
	bullet.configure(shooter, self, origin, initial_velocity, damage, headshot_rule,
		weapon_kind)


func perform_melee(shooter: Node3D, origin: Vector3, direction: Vector3,
		combo: int) -> Node3D:
	var strike_direction := direction.normalized()
	var strike_shape := SphereShape3D.new()
	strike_shape.radius = MELEE_RADIUS
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = strike_shape
	query.transform = Transform3D(Basis.IDENTITY,
		origin + strike_direction * 0.72 + Vector3.UP * 0.20)
	query.collision_mask = 1 | CombatHitbox.HITBOX_LAYER
	query.collide_with_areas = true
	query.collide_with_bodies = true
	if shooter is CollisionObject3D:
		query.exclude = [shooter.get_rid()]
	var hits := get_world_3d().direct_space_state.intersect_shape(query, 24)
	var best_target: Node3D
	var best_distance := INF
	for result in hits:
		var collider = result.collider
		var target: Node3D
		if collider is CombatHitbox:
			target = collider.actor
		elif collider is Node3D and collider.has_method("take_damage"):
			target = collider
		if not target or target == shooter or not target.has_method("take_damage"):
			continue
		var to_target := target.global_position - origin
		var distance := to_target.length()
		if distance < 0.01 or to_target.normalized().dot(strike_direction) < 0.10:
			continue
		if distance < best_distance:
			best_distance = distance
			best_target = target
	if not best_target:
		return null
	var combo_index := posmod(combo, MELEE_DAMAGE.size())
	var impulse := strike_direction * (5.0 + combo_index * 1.25) \
		+ Vector3.UP * (1.1 + combo_index * 0.45)
	best_target.take_damage(melee_damage_for_combo(combo), shooter, impulse)
	Sfx.play_at("melee_hit",
		best_target.global_position + Vector3.UP * 0.75, -3.0)
	return best_target


## Network strikes encode the authoritative primed bit in combos 3..5. Values
## outside that canonical range remain ordinary combos instead of gaining an
## accidental damage bonus from malformed input.
static func melee_damage_for_combo(encoded_combo: int) -> float:
	var combo_index := posmod(encoded_combo, MELEE_DAMAGE.size())
	var primed := encoded_combo >= MELEE_DAMAGE.size() \
		and encoded_combo < MELEE_DAMAGE.size() * 2
	return MELEE_DAMAGE[combo_index] * (MELEE_PRIMED_DAMAGE_MULTIPLIER \
		if primed else 1.0)


func _on_network_bullet(shooter_id: int, origin: Vector3,
		initial_velocity: Vector3, damage: float, headshot_rule: bool,
		play_fx: bool, weapon_kind: int) -> void:
	if not _network_transient_effects_enabled:
		return
	var shooter: Node3D
	if local_player and shooter_id == local_player.peer_id:
		shooter = local_player
	elif puppets.has(shooter_id):
		shooter = puppets[shooter_id]
		if play_fx:
			shooter.on_shot(initial_velocity.normalized(), weapon_kind)
	spawn_bullet(shooter, origin, initial_velocity, damage, headshot_rule,
		weapon_kind)
	if play_fx:
		var sound_name := "gunshot"
		var sound_volume := -2.0
		var sound_range := 60.0
		if weapon_kind == Net.WEAPON_SHOTGUN:
			sound_name = "shotgun"
			sound_volume = -1.0
		elif weapon_kind == Net.WEAPON_SMG:
			sound_name = "smg"
			sound_volume = -4.0
		elif weapon_kind == Net.WEAPON_SNIPER:
			sound_name = "sniper"
			sound_volume = 2.0
			sound_range = 240.0
		Sfx.play_at(sound_name, origin, sound_volume, 1.0, sound_range)
		spawn_muzzle_flash(origin, initial_velocity.normalized())


func _on_network_melee(shooter_id: int, origin: Vector3,
		direction: Vector3, combo: int) -> void:
	if not _network_transient_effects_enabled:
		return
	var shooter: Node3D
	if local_player and shooter_id == local_player.peer_id:
		shooter = local_player
	elif puppets.has(shooter_id):
		shooter = puppets[shooter_id]
		shooter.on_melee(direction, combo)
	perform_melee(shooter, origin, direction, combo)


func spawn_muzzle_flash(origin: Vector3, direction: Vector3) -> void:
	var flash := MeshInstance3D.new()
	flash.mesh = _muzzle_mesh
	flash.material_override = _muzzle_material
	flash.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(flash)
	flash.global_position = origin + direction * 0.08
	var tween := flash.create_tween()
	tween.tween_property(flash, "scale", Vector3.ONE * 2.8, 0.075)
	tween.tween_callback(flash.queue_free)


func spawn_bullet_impact(pos: Vector3, normal: Vector3, hit_actor: bool) -> void:
	var impact := MeshInstance3D.new()
	impact.mesh = _impact_mesh
	impact.material_override = _impact_actor_material if hit_actor \
		else _impact_world_material
	impact.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(impact)
	impact.global_position = pos + normal * 0.04
	var tween := impact.create_tween()
	tween.tween_property(impact, "scale", Vector3.ONE * 3.2, 0.13)
	tween.tween_callback(impact.queue_free)


func report_headshot(source: Node3D, target: Node3D, lethal: bool,
		distance: float) -> void:
	headshot_scored.emit(source, target, lethal, distance)


static func _prepare_combat_fx() -> void:
	if _muzzle_mesh:
		return
	_muzzle_mesh = SphereMesh.new()
	_muzzle_mesh.radius = 0.075
	_muzzle_mesh.height = 0.15
	_muzzle_mesh.radial_segments = 6
	_muzzle_mesh.rings = 3
	_muzzle_material = _unshaded_emission_material(
		Color(1.0, 0.78, 0.18), Color(1.0, 0.34, 0.02), 4.0)
	_impact_mesh = SphereMesh.new()
	_impact_mesh.radius = 0.055
	_impact_mesh.height = 0.11
	_impact_mesh.radial_segments = 5
	_impact_mesh.rings = 2
	_impact_world_material = _unshaded_emission_material(
		Color(1.0, 0.72, 0.12), Color(1.0, 0.72, 0.12), 2.5)
	_impact_actor_material = _unshaded_emission_material(
		Color(1.0, 0.18, 0.06), Color(1.0, 0.18, 0.06), 2.5)


static func _unshaded_emission_material(albedo: Color, emission: Color,
		energy: float) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = albedo
	material.emission_enabled = true
	material.emission = emission
	material.emission_energy_multiplier = energy
	return material


func actor_defeated(actor: MonkeyPlayer, source: Node3D, hit_zone := "body",
		impact_impulse := Vector3.ZERO) -> void:
	if actor.state == actor.S.SWING:
		actor._release(false)
	actor.begin_defeat(hit_zone, impact_impulse)
	var defeat_sequence := actor.defeat_sequence
	var source_id := 0
	if source is MonkeyPlayer or source is Puppet:
		source_id = source.peer_id
		combat_kills[source_id] = int(combat_kills.get(source_id, 0)) + 1
		combat_score_changed.emit()
	await get_tree().create_timer(DEFEAT_VIEW_TIME).timeout
	if not is_instance_valid(actor) or not actor.defeated \
			or actor.defeat_sequence != defeat_sequence:
		return
	if actor == local_player and expedition_manager \
			and is_instance_valid(expedition_manager) \
			and expedition_manager.respawn_local_player_after_defeat(actor):
		return
	var x := -4.0 if actor == local_player else 12.0
	var z := 4.0 if actor == local_player else -14.0
	actor.revive_at(Vector3(x, Gen.height(x, z) + 2.2, z))


func height_at(x: float, z: float) -> float:
	return Gen.height(x, z)


func water_surface_y(x: float, z: float) -> float:
	return Visuals.water_surface_y(x, z, _t)


# ---- streaming -------------------------------------------------------------

func _track_ground_actor_collision(actor: Node3D, focus: Vector3) -> bool:
	if not is_instance_valid(actor) or actor.is_queued_for_deletion() \
			or actor == local_player:
		return false
	var horizontal_delta := Vector2(actor.global_position.x - focus.x,
		actor.global_position.z - focus.z)
	var range_limit := Gen.CHUNK * float(GROUND_ACTOR_COLLISION_RANGE_CHUNKS)
	if horizontal_delta.length_squared() > range_limit * range_limit:
		return false
	var ground := Gen.height(actor.global_position.x, actor.global_position.z)
	if actor.global_position.y - ground > GROUND_COLLISION_ALTITUDE_MARGIN:
		return false
	var center := Vector2i(floori(actor.global_position.x / Gen.CHUNK),
		floori(actor.global_position.z / Gen.CHUNK))
	if not _ground_actor_collision_centers.has(center):
		_ground_actor_collision_centers.append(center)
	return true


func _refresh_terrain_clearance_probe(player_pos: Vector3,
		velocity: Vector3) -> void:
	var now := Time.get_ticks_usec()
	var moved := player_pos.distance_squared_to(_terrain_probe_position) \
		>= TERRAIN_PROBE_MAX_TRAVEL * TERRAIN_PROBE_MAX_TRAVEL
	var velocity_changed := velocity.distance_squared_to(_terrain_probe_velocity) \
		>= TERRAIN_PROBE_VELOCITY_DELTA * TERRAIN_PROBE_VELOCITY_DELTA
	if _terrain_probe_usec > 0 and not moved and not velocity_changed \
			and now - _terrain_probe_usec < TERRAIN_PROBE_MAX_AGE_USEC:
		return
	_terrain_probe_position = player_pos
	_terrain_probe_velocity = velocity
	_terrain_probe_usec = now
	_terrain_probe_ground = Gen.height(player_pos.x, player_pos.z)
	var vertical_end := player_pos.y \
		+ minf(velocity.y, 0.0) * DESCENT_COLLISION_LOOKAHEAD
	var local_clearance := player_pos.y - _terrain_probe_ground
	_terrain_probe_detail_clearance = minf(local_clearance,
		vertical_end - _terrain_probe_ground)
	# Above the globally highest possible terrain, one local height sample is
	# enough to drive visual LOD and collision is mathematically impossible. This
	# removes the full planet/road height pipeline from ordinary cruise frames.
	if minf(player_pos.y, vertical_end) \
			> Gen.PLANET_SUMMIT_ELEVATION + GROUND_COLLISION_ALTITUDE_MARGIN:
		_terrain_probe_collision_clearance = minf(player_pos.y, vertical_end) \
			- Gen.PLANET_SUMMIT_ELEVATION
		return
	var horizontal_velocity := Vector2(velocity.x, velocity.z)
	var travel := horizontal_velocity.length() * DESCENT_COLLISION_LOOKAHEAD
	var sample_count := clampi(ceili(travel / TERRAIN_PROBE_SPACING), 1,
		TERRAIN_PROBE_MAX_SAMPLES)
	var minimum_clearance := _terrain_probe_detail_clearance
	for sample_index in range(1, sample_count + 1):
		var alpha := float(sample_index) / float(sample_count)
		var seconds := DESCENT_COLLISION_LOOKAHEAD * alpha
		var sample_pos := player_pos + velocity * seconds
		var terrain_y := Gen.height(sample_pos.x, sample_pos.z)
		minimum_clearance = minf(minimum_clearance, sample_pos.y - terrain_y)
	_terrain_probe_collision_clearance = minimum_clearance
	_terrain_probe_detail_clearance = minimum_clearance


func _update_collision_requirement(player_pos: Vector3) -> void:
	var velocity := _stream_focus_velocity()
	_refresh_terrain_clearance_probe(player_pos, velocity)
	var clearance := player_pos.y - _terrain_probe_ground
	# Sample the complete forward trajectory as well as vertical descent. A level
	# aircraft approaching a rising mountain therefore wakes terrain/collision
	# several seconds before contact instead of after reaching the slope.
	var predicted_clearance := _terrain_probe_collision_clearance
	_local_ground_clearance = clearance
	# Wake literal detail from predicted rather than current clearance while
	# descending. Collision retains its tighter 18 m safety contract below, but
	# terrain dressing is already resident before the camera reaches tree range.
	var detail_clearance := minf(clearance, _terrain_probe_detail_clearance)
	_update_far_foliage_clearance(detail_clearance)
	_set_literal_detail_suppressed(literal_detail_should_be_suppressed(
		detail_clearance, _literal_detail_suppressed))
	_local_collision_required = clearance <= GROUND_COLLISION_ALTITUDE_MARGIN \
		or predicted_clearance <= GROUND_COLLISION_ALTITUDE_MARGIN
	_ground_actor_collision_centers.clear()
	_tracked_ground_vehicle_count = 0
	if ai_opponent and is_instance_valid(ai_opponent):
		_track_ground_actor_collision(ai_opponent, player_pos)
	for actor in friendly_monkeys:
		if actor is Node3D:
			_track_ground_actor_collision(actor, player_pos)
	for actor in puppets.values():
		if actor is Node3D:
			_track_ground_actor_collision(actor, player_pos)
	# Parked rigid bodies need the same terrain floor while the local player is
	# flying overhead. High aircraft naturally fail the clearance test, while a
	# nearby Jeep, bike, boat, or landed jet keeps a 3x3 collision safety patch.
	for actor in vehicles.values():
		if actor is Node3D \
				and _track_ground_actor_collision(actor as Node3D, player_pos):
			_tracked_ground_vehicle_count += 1
	_ground_collision_required = _local_collision_required \
		or not _ground_actor_collision_centers.is_empty()


func _set_literal_detail_suppressed(suppressed: bool) -> void:
	if suppressed == _literal_detail_suppressed:
		return
	_literal_detail_suppressed = suppressed
	var literal_visible := not suppressed
	for chunk_value in chunks.values():
		var chunk := chunk_value as Chunk
		if is_instance_valid(chunk):
			chunk.set_literal_foliage_visible(literal_visible)
	# Suspended work is not scheduler debt. On descent, restart wait clocks and
	# enqueue only the current playable shell; predictive terrain remains shell-only.
	if not suppressed:
		var now := Time.get_ticks_usec()
		for queue in [_horizon_detail_queue, _skyline_detail_queue]:
			for node in queue:
				if is_instance_valid(node):
					node.set_meta(STREAM_DETAIL_ENQUEUED_META, now)
	_reconcile_chunk_detail_queue()


func _update_far_foliage_clearance(clearance: float) -> void:
	var suppress_horizon := clearance > (HORIZON_FOLIAGE_RESUME_CLEARANCE
		if _horizon_foliage_suppressed else HORIZON_FOLIAGE_SUSPEND_CLEARANCE)
	var suppress_skyline := clearance > (SKYLINE_FOLIAGE_RESUME_CLEARANCE
		if _skyline_foliage_suppressed else SKYLINE_FOLIAGE_SUSPEND_CLEARANCE)
	var now := Time.get_ticks_usec()
	if suppress_horizon != _horizon_foliage_suppressed:
		_horizon_foliage_suppressed = suppress_horizon
		for sector_value in horizon_chunks.values():
			var sector := sector_value as HorizonChunk
			if is_instance_valid(sector):
				sector.set_literal_foliage_visible(not suppress_horizon)
		if not suppress_horizon:
			for sector in _horizon_detail_queue:
				if is_instance_valid(sector):
					sector.set_meta(STREAM_DETAIL_ENQUEUED_META, now)
	if suppress_skyline != _skyline_foliage_suppressed:
		_skyline_foliage_suppressed = suppress_skyline
		for sector_value in skyline_chunks.values():
			var sector := sector_value as SkylineChunk
			if is_instance_valid(sector):
				sector.set_literal_foliage_visible(not suppress_skyline)
		if not suppress_skyline:
			for sector in _skyline_detail_queue:
				if is_instance_valid(sector):
					sector.set_meta(STREAM_DETAIL_ENQUEUED_META, now)
	_update_altitude_lod_handoffs()


func _update_altitude_lod_handoffs() -> void:
	# On ascent, a successor immediately takes full ownership before the outgoing
	# tier reaches its 3D visibility limit. On descent, keep that full successor
	# coverage until the complete lower shell is resident again; rebuilding a
	# freed 7x7/5x5 tier can take several bounded frames.
	_horizon_handoff_ready = not _horizon_foliage_suppressed \
		and _missing_square(horizon_chunks, center_horizon_sector(),
			Gen.HORIZON_VIEW_R) == 0
	_skyline_handoff_ready = not _skyline_foliage_suppressed \
		and _missing_square(skyline_chunks, center_skyline_sector(),
			Gen.SKYLINE_VIEW_R) == 0
	Visuals.set_altitude_lod_handoffs(
		Gen.SKYLINE_NEAR_FADE if _horizon_handoff_ready \
			else FLIGHT_TERRAIN_NEAR_FADE,
		Gen.STRATOS_NEAR_FADE if _skyline_handoff_ready \
			else FLIGHT_TERRAIN_NEAR_FADE)

func center_chunk() -> Vector2i:
	var c := _stream_focus_position()
	return Vector2i(floori(c.x / Gen.CHUNK), floori(c.z / Gen.CHUNK))


## An online camera must not clip a replicated jet merely because terrain near
## the ground is intentionally streamed only 2.2 km. Raising a reverse-Z far
## plane does not expand any chunk ring; it only exposes the one-draw jet LOD.
static func gameplay_camera_far_distance(streamed_distance: float,
		multiplayer_active: bool) -> float:
	var desired := streamed_distance * 1.15
	if multiplayer_active:
		desired = maxf(desired, FighterJet.LONG_RANGE_CAMERA_FAR)
	return clampf(desired, 1200.0, 30000.0)


func _process(dt: float) -> void:
	if not is_build_complete():
		return
	_update_pending_vehicle_entry()
	_t += dt
	_update_day_night(dt)
	if _earth_streaming_enabled:
		_wrap_local_planet_actor()
	if _earth_streaming_enabled or _expedition_stream_focus.is_finite():
		if _expedition_stream_focus.is_finite():
			current_view_distance = Gen.VIEW_BASE_DISTANCE
			Visuals.set_stratos_view_radius(current_view_distance)
		_stream()
	if local_player:
		Visuals.set_far_focus(_stream_focus_position())
		if _earth_streaming_enabled:
			_update_biome_ambience(dt)
		_particles.global_position = local_player.global_position
		var tgt: Dictionary = local_player.last_target
		if not tgt.is_empty():
			_marker.visible = true
			# ring circles the grab point, facing the camera, gently pulsing
			var pt: Vector3 = tgt.point
			var cp: Vector3 = local_player.cam.cam_pos() if local_player.cam else pt + Vector3(0, 0, 4)
			var yv := cp - pt
			yv = yv.normalized() if yv.length() > 0.05 else Vector3.UP
			var xv := yv.cross(Vector3.UP)
			if xv.length() < 0.05:
				xv = yv.cross(Vector3.RIGHT)
			xv = xv.normalized()
			var zv := xv.cross(yv)
			var s := 1.0 + sin(_t * 7.0) * 0.15
			_marker.global_transform = Transform3D(Basis(xv * s, yv * s, zv * s), pt)
		else:
			_marker.visible = false


## Lunar terrain is a separate bounded world. Pausing only the Earth streaming
## scheduler avoids spending chunk work around the Moon's elevated coordinates;
## the retained shell is reused immediately after return or splashdown.
func set_earth_streaming_enabled(enabled: bool) -> void:
	_earth_streaming_enabled = enabled
	if _particles and not enabled:
		_particles.emitting = false
	if seasonal_weather:
		seasonal_weather.set_atmosphere_enabled(enabled)
	if enabled:
		_reset_planet_stream_focus()


## The voyage keeps already-built ground visible while it is still readable,
## then retires the four bounded terrain tiers and Earth lighting once the
## opaque globe is directly behind them. This does not free or rebuild chunks, so return to
## Earth is immediate and the handoff costs no per-frame allocations.
func set_earth_transit_surface_visible(enabled: bool, light_weight := -1.0) -> void:
	# Return flight approaches a remote ocean tile before local chunks are
	# resident. Its sunlight must fade in independently of that terrain reveal.
	var desired_light := (1.0 if enabled else 0.0) if light_weight < 0.0 \
		else clampf(light_weight, 0.0, 1.0)
	if not is_equal_approx(_earth_transit_light_weight, desired_light):
		_earth_transit_light_weight = desired_light
		_apply_earth_transit_light()
	if _earth_transit_surface_visible == enabled:
		return
	_earth_transit_surface_visible = enabled
	_set_lunar_shadow_filter(not enabled)
	for tier: Dictionary in [chunks, horizon_chunks, skyline_chunks,
			stratos_chunks]:
		for node_value: Variant in tier.values():
			var terrain_node := node_value as Node3D
			if is_instance_valid(terrain_node):
				terrain_node.visible = enabled


func _apply_earth_transit_light() -> void:
	# Keep the seasonal energy unscaled so day/night updates cannot cancel the
	# cinematic fade, and returning to gameplay restores the exact current light.
	if _sun:
		_sun.visible = _earth_transit_light_weight > 0.001
		_sun.light_energy = _sun_daylight_energy * _earth_transit_light_weight
	if _moon:
		_moon.visible = _earth_transit_light_weight > 0.001
		_moon.light_energy = _moon_daylight_energy * _earth_transit_light_weight


func _set_lunar_shadow_filter(enabled: bool) -> void:
	if enabled == _lunar_shadow_quality_active:
		return
	if enabled:
		_earth_shadow_filter_quality = int(ProjectSettings.get_setting(
			"rendering/lights_and_shadows/directional_shadow/soft_shadow_filter_quality", 2))
		# Crisp, airless lunar sunlight needs one depth sample, not a broad
		# filtered penumbra that blurs the boot contact and costs fill rate.
		RenderingServer.directional_soft_shadow_filter_set_quality(RenderingServer.SHADOW_QUALITY_HARD)
	else:
		RenderingServer.directional_soft_shadow_filter_set_quality(_earth_shadow_filter_quality)
	_lunar_shadow_quality_active = enabled


func _exit_tree() -> void:
	_set_lunar_shadow_filter(false)


func earth_transit_surface_visible() -> bool:
	return _earth_transit_surface_visible


func earth_streaming_enabled() -> bool:
	return _earth_streaming_enabled


func set_expedition_stream_focus(position: Vector3) -> void:
	if not position.is_finite():
		clear_expedition_stream_focus()
		return
	if _expedition_stream_focus.is_finite() \
			and _expedition_stream_focus.distance_squared_to(position) < 0.01:
		return
	_expedition_stream_focus = position
	_reset_planet_stream_focus()


func clear_expedition_stream_focus() -> void:
	if not _expedition_stream_focus.is_finite():
		return
	_expedition_stream_focus = Vector3(INF, INF, INF)
	_reset_planet_stream_focus()


func _stream_focus_position() -> Vector3:
	return _expedition_stream_focus if _expedition_stream_focus.is_finite() \
		else (local_player.global_position if local_player else Vector3.ZERO)


func _stream_focus_velocity() -> Vector3:
	return Vector3.ZERO if _expedition_stream_focus.is_finite() \
		else (local_player.velocity if local_player else Vector3.ZERO)


func _wrap_local_planet_actor() -> void:
	if not local_player or local_player.expedition_locked:
		return
	var source := local_player.global_position
	var driven_vehicle: Vehicle = local_player.vehicle
	if driven_vehicle and is_instance_valid(driven_vehicle):
		source = driven_vehicle.global_position
	var source_xz := Vector2(source.x, source.z)
	var canonical: Dictionary = Gen.canonical_world_sample(source_xz)
	var destination: Vector2 = canonical.xz
	if destination.distance_squared_to(source_xz) <= 0.000001:
		return
	var yaw_delta := float(canonical.yaw_delta)
	if driven_vehicle and is_instance_valid(driven_vehicle):
		driven_vehicle.apply_planet_wrap(destination, yaw_delta)
		local_player.global_position = driven_vehicle.seat_global()
		local_player.velocity = driven_vehicle.linear_velocity
		local_player.reset_physics_interpolation()
		if local_player.cam:
			local_player.cam.apply_planet_heading_delta(yaw_delta)
	else:
		local_player.apply_planet_wrap(destination, yaw_delta)
	_reset_planet_stream_focus()


func _reset_planet_stream_focus() -> void:
	_stream_center = Vector2i(0x3fffffff, 0x3fffffff)
	_prefetch_center = _stream_center
	_near_guard_radius_state = -99
	_terrain_probe_position = Vector3(INF, INF, INF)
	_terrain_probe_usec = 0
	_horizon_center = _stream_center
	_horizon_prefetch_center = _stream_center
	_skyline_center = _stream_center
	_stratos_center = _stream_center
	_stratos_prefetch_center = _stream_center
	_stratos_ring = -1
	_stratos_target_focus = Vector2(INF, INF)
	_stratos_prefetch_focus = Vector2(INF, INF)
	_stratos_target_radius = -1.0
	if is_instance_valid(_active_stratos_sector):
		_active_stratos_sector.queue_free()
	_active_stratos_sector = null
	_active_stratos_key = Vector2i(0x3fffffff, 0x3fffffff)
	_active_stratos_started_usec = 0
	# A wrap or Moon round-trip invalidates queued coordinate priorities. Rebuild
	# shell queues against the canonical destination on the next _stream() call
	# instead of preserving timestamps from the old side of the planet. Detail
	# nodes remain valid Earth content, so keep them but restart their wait clocks;
	# otherwise time intentionally spent with Earth streaming paused is reported as
	# scheduler starvation immediately after return.
	_queue.clear()
	_near_pending.clear()
	_near_enqueued_at.clear()
	_horizon_queue.clear()
	_horizon_pending.clear()
	_horizon_enqueued_at.clear()
	_skyline_queue.clear()
	_skyline_pending.clear()
	_skyline_enqueued_at.clear()
	_stratos_queue.clear()
	_stratos_enqueued_at.clear()
	var now := Time.get_ticks_usec()
	for detail_queue in [_chunk_detail_queue, _horizon_detail_queue,
			_skyline_detail_queue]:
		for node in detail_queue:
			if is_instance_valid(node):
				node.set_meta(STREAM_DETAIL_ENQUEUED_META, now)


func _update_biome_ambience(dt: float) -> void:
	if not _environment or not local_player:
		return
	_biome_sample_timer -= dt
	if _biome_sample_timer <= 0.0:
		_biome_sample_timer = 0.45
		match Gen.biome_at(local_player.global_position.x,
				local_player.global_position.z):
			Gen.Biome.BAMBOO_GROVE:
				_biome_fog_target = Color(0.53, 0.66, 0.38)
				_biome_density_target = 0.00086
				_biome_saturation_target = 1.02
			Gen.Biome.WETLAND:
				_biome_fog_target = Color(0.34, 0.58, 0.53)
				_biome_density_target = 0.00120
				_biome_saturation_target = 0.99
			Gen.Biome.HIGHLAND:
				_biome_fog_target = Color(0.56, 0.67, 0.62)
				_biome_density_target = 0.00137
				_biome_saturation_target = 0.96
			Gen.Biome.PLAINS:
				_biome_fog_target = Color(0.61, 0.70, 0.53)
				_biome_density_target = 0.00072
				_biome_saturation_target = 1.02
			Gen.Biome.GRASSLAND:
				_biome_fog_target = Color(0.52, 0.69, 0.43)
				_biome_density_target = 0.00076
				_biome_saturation_target = 1.02
			Gen.Biome.ROCKY_MOUNTAINS:
				_biome_fog_target = Color(0.69, 0.74, 0.78)
				_biome_density_target = 0.00058
				_biome_saturation_target = 0.88
			Gen.Biome.DESERT:
				_biome_fog_target = Color(0.77, 0.63, 0.43)
				_biome_density_target = 0.00068
				_biome_saturation_target = 0.94
			Gen.Biome.TUNDRA:
				_biome_fog_target = Color(0.65, 0.70, 0.69)
				_biome_density_target = 0.00093
				_biome_saturation_target = 0.82
			Gen.Biome.ICE:
				_biome_fog_target = Color(0.77, 0.85, 0.92)
				_biome_density_target = 0.00108
				_biome_saturation_target = 0.76
			Gen.Biome.OCEAN:
				_biome_fog_target = Color(0.38, 0.57, 0.68)
				_biome_density_target = 0.00082
				_biome_saturation_target = 0.92
			Gen.Biome.LAKE:
				_biome_fog_target = Color(0.43, 0.62, 0.60)
				_biome_density_target = 0.00094
				_biome_saturation_target = 0.96
			_:
				_biome_fog_target = Color(0.43, 0.61, 0.43)
				_biome_density_target = 0.00100
				_biome_saturation_target = 1.0
	# Altitude buys horizon, but over the planet's complete elevation range. The
	# old linear Gen helper saturated by ~83 m and forced an 81-sector satellite
	# square over ordinary hills.
	var altitude: float = local_player.global_position.y
	_apply_altitude_sky(altitude)
	var target_far := stream_view_distance_for_altitude(altitude)
	current_view_distance = lerpf(current_view_distance, target_far,
		1.0 - exp(-0.55 * dt))
	Visuals.set_stratos_view_radius(current_view_distance)
	if local_player.cam:
		local_player.cam.set_far_distance(gameplay_camera_far_distance(
			current_view_distance, Net.active))
	if _literal_detail_suppressed and not _altitude_quality_low:
		_altitude_quality_low = true
		_sun.directional_shadow_max_distance = 45.0
		_environment.ssao_enabled = false
	elif not _literal_detail_suppressed and _altitude_quality_low:
		_altitude_quality_low = false
		_apply_effect_quality()
	var night_fog := Color(0.055, 0.075, 0.13)
	var fog_target := night_fog.lerp(_biome_fog_target,
		0.16 + daylight_amount * 0.84)
	var density_multiplier := lerpf(1.16, 1.0, daylight_amount)
	var saturation_multiplier := 1.0
	match weather:
		SeasonalCycle.Weather.RAIN:
			fog_target = fog_target.lerp(Color(0.34, 0.43, 0.49), 0.30)
			density_multiplier *= 1.34
			saturation_multiplier = 0.91
		SeasonalCycle.Weather.FALLING_LEAVES:
			fog_target = fog_target.lerp(Color(0.62, 0.43, 0.25), 0.08)
			saturation_multiplier = 1.03
		SeasonalCycle.Weather.SNOW:
			fog_target = fog_target.lerp(Color(0.70, 0.78, 0.86), 0.25)
			density_multiplier *= 1.18
			saturation_multiplier = 0.88
	_environment.fog_light_color = _environment.fog_light_color.lerp(
		fog_target, 1.0 - exp(-0.42 * dt))
	_environment.fog_density = lerpf(_environment.fog_density,
		minf(_biome_density_target, 3.2 / current_view_distance) * density_multiplier * (1.0-_space_sky_weight),
		1.0 - exp(-0.42 * dt))
	_environment.adjustment_saturation = lerpf(
		_environment.adjustment_saturation,
		_biome_saturation_target * saturation_multiplier,
		1.0 - exp(-0.38 * dt))


func _update_day_night(dt: float) -> void:
	if _time_override_hour >= 0.0:
		_time_override_elapsed += dt
		time_of_day_hours = SeasonalCycle.hour_after_elapsed(
			_time_override_hour, _time_override_elapsed)
	else:
		time_of_day_hours = SeasonalCycle.hour_after_elapsed(
			time_of_day_hours, dt)
		_clock_resync_timer -= dt
		if _clock_resync_timer <= 0.0:
			_clock_resync_timer = CLOCK_RESYNC_STEP
			time_of_day_hours = Net.authoritative_cycle_hour()

	_calendar_check_timer -= dt
	if _calendar_check_timer <= 0.0:
		_calendar_check_timer = CALENDAR_CHECK_STEP
		if not _season_override_active:
			var calendar_season := SeasonalCycle.season_from_system()
			if calendar_season != season:
				_apply_season(calendar_season)

	_lighting_update_timer -= dt
	_sky_update_timer -= dt
	if _lighting_update_timer <= 0.0:
		_lighting_update_timer = LIGHTING_UPDATE_STEP
		var update_sky := _sky_update_timer <= 0.0
		if update_sky:
			_sky_update_timer = SKY_UPDATE_STEP
		_apply_day_night(update_sky)


func _apply_day_night(update_sky: bool) -> void:
	if not _environment or not _sun or not _moon or not _celestial_sky:
		return
	var elevation := SeasonalCycle.solar_elevation_for_hour(time_of_day_hours)
	daylight_amount = smoothstep(-0.10, 0.14, elevation)
	var high_sun := smoothstep(0.06, 0.72, maxf(elevation, 0.0))
	var twilight := 1.0 - smoothstep(0.02, 0.34, absf(elevation))
	var solar_rotation := -(time_of_day_hours - 6.0) / 24.0 * TAU
	_sun.rotation = Vector3(solar_rotation, deg_to_rad(-34.0), deg_to_rad(-7.0))
	_moon.rotation = Vector3(solar_rotation + PI, deg_to_rad(-34.0), deg_to_rad(-7.0))

	var weather_light := 1.0
	match weather:
		SeasonalCycle.Weather.RAIN:
			weather_light = 0.70
		SeasonalCycle.Weather.FALLING_LEAVES:
			weather_light = 0.90
		SeasonalCycle.Weather.SNOW:
			weather_light = 0.82
	# Daytime fog can softly unify the canopy and sky, but that same green
	# contribution turns a clear midnight teal. Keep clear nights navy while
	# allowing rain and snow to retain a believable veil over the stars.
	_environment.fog_sky_affect = lerpf(
		0.025 + (1.0 - weather_light) * 0.12, 0.12, daylight_amount) * (1.0-_space_sky_weight)
	var sunrise_color := Color(1.0, 0.42, 0.16)
	var noon_color := Color(1.0, 0.955, 0.86)
	_sun.light_color = sunrise_color.lerp(noon_color, high_sun)
	_sun_daylight_energy = daylight_amount * lerpf(0.44, 1.36, high_sun) \
		* weather_light
	_sun.shadow_enabled = daylight_amount > 0.08
	_moon_daylight_energy = (1.0 - daylight_amount) * 0.27 * weather_light
	_apply_earth_transit_light()
	# Cloudy seasonal weather attenuates the visible disc more strongly than the
	# diffuse moonlight, so rain and snow do not leave a pasted-on white circle.
	_moon_visual_strength = (1.0 - daylight_amount) * MOON_SKY_ENERGY \
		* weather_light * weather_light
	_environment.ambient_light_energy = lerpf(0.20, 0.46,
		daylight_amount) * lerpf(0.90, weather_light, 0.58)
	_environment.tonemap_exposure = lerpf(0.87, 0.96, daylight_amount)
	_environment.adjustment_brightness = lerpf(0.91, 0.98, daylight_amount)
	if _particles:
		_particles.emitting = season == SeasonalCycle.Season.SUMMER \
			and daylight_amount < 0.52 and _earth_streaming_enabled

	if not update_sky or not _sky_material or not _celestial_sky:
		return
	var storm := 1.0 - weather_light
	var night_top := Color(0.027, 0.082, 0.239)
	var day_top := Color(0.075, 0.29, 0.64)
	var night_horizon := Color(0.063, 0.169, 0.357)
	var day_horizon := Color(0.58, 0.77, 0.89)
	var twilight_horizon := Color(1.0, 0.31, 0.095)
	var sky_top := night_top.lerp(day_top, daylight_amount)
	var sky_horizon := night_horizon.lerp(day_horizon, daylight_amount)
	sky_horizon = sky_horizon.lerp(twilight_horizon,
		twilight * (0.82 - high_sun * 0.54))
	sky_top = sky_top.lerp(Color(0.22, 0.27, 0.32), storm * 0.68)
	sky_horizon = sky_horizon.lerp(Color(0.40, 0.45, 0.49), storm * 0.56)
	# The sky shader already wraps a complete inward-facing sphere. Feed its lower
	# hemisphere an altitude-aware atmospheric palette so looking below the
	# terrain horizon cannot reveal the old dark nadir spot.
	var nadir_palette := Visuals.full_sphere_nadir_palette(sky_top, sky_horizon,
		daylight_amount, _local_ground_clearance)
	var ground_bottom: Color = nadir_palette.bottom
	var ground_horizon: Color = nadir_palette.horizon
	var sky_energy := lerpf(0.68, 0.92, daylight_amount) \
		* lerpf(1.0, weather_light, 0.48)
	_celestial_sky.update_palette(sky_top, sky_horizon,
		ground_bottom, ground_horizon, sky_energy)
	_celestial_sky.update_celestials(daylight_amount, weather_light,
		moon_source_direction(), _moon_visual_strength, time_of_day_hours,
		_sun.global_basis.z.normalized())


func _stream() -> void:
	var cc := center_chunk()
	var player_pos := _stream_focus_position()
	var stream_velocity := _stream_focus_velocity()
	var horizontal_velocity := Vector2(stream_velocity.x, stream_velocity.z)
	_stream_speed_mps = horizontal_velocity.length()
	_update_collision_requirement(player_pos)

	var predicted := _predicted_near_center(cc)
	# Actor collision patches can cross a chunk boundary while the local player and
	# its predictive center remain unchanged. Refresh collision targets first and
	# rebuild the near shell set whenever that membership changes.
	var collision_targets_changed := _refresh_collision_targets(cc, predicted)
	var near_guard_changed := _near_guard_radius_state != _near_guard_radius()
	if cc != _stream_center or predicted != _prefetch_center \
			or collision_targets_changed or near_guard_changed:
		_refresh_near_targets(cc, predicted)
	var hc := center_horizon_sector()
	var horizon_sector_size := Gen.CHUNK * Gen.HORIZON_SECTOR_CHUNKS
	var horizon_lead := Vector2(player_pos.x, player_pos.z) \
		+ horizontal_velocity * HORIZON_PREDICTION_TIME
	var predicted_hc := Vector2i(floori(horizon_lead.x / horizon_sector_size),
		floori(horizon_lead.y / horizon_sector_size))
	var horizon_offset := predicted_hc - hc
	predicted_hc = hc + Vector2i(clampi(horizon_offset.x,
		-HORIZON_PREDICTION_MAX_SECTORS, HORIZON_PREDICTION_MAX_SECTORS),
		clampi(horizon_offset.y, -HORIZON_PREDICTION_MAX_SECTORS,
			HORIZON_PREDICTION_MAX_SECTORS))
	if _horizon_foliage_suppressed:
		if not horizon_chunks.is_empty() or not _horizon_targets.is_empty() \
				or _horizon_center.x != 0x3fffffff:
			_suspend_horizon_stream()
	elif hc != _horizon_center or predicted_hc != _horizon_prefetch_center:
		_refresh_horizon_targets(hc, predicted_hc)
	var sc := center_skyline_sector()
	if _skyline_foliage_suppressed:
		if not skyline_chunks.is_empty() or not _skyline_queue.is_empty() \
				or _skyline_center.x != 0x3fffffff:
			_suspend_skyline_stream()
	elif sc != _skyline_center:
		_refresh_skyline_targets(sc)
	var stratos_sector_size := Gen.CHUNK * Gen.STRATOS_SECTOR_CHUNKS
	var stratos_focus := Vector2(player_pos.x, player_pos.z)
	var stc := Vector2i(floori(stratos_focus.x / stratos_sector_size),
		floori(stratos_focus.y / stratos_sector_size))
	var stratos_lead := stratos_focus \
		+ horizontal_velocity * STRATOS_PREDICTION_TIME
	var predicted_stc := Vector2i(floori(stratos_lead.x / stratos_sector_size),
		floori(stratos_lead.y / stratos_sector_size))
	var stratos_offset := predicted_stc - stc
	predicted_stc = stc + Vector2i(clampi(stratos_offset.x, -1, 1),
		clampi(stratos_offset.y, -1, 1))
	var ring := clampi(ceili(current_view_distance / stratos_sector_size), 1, 4)
	var stratos_focus_changed := not _stratos_target_focus.is_finite() \
		or _stratos_target_focus.distance_squared_to(stratos_focus) \
			>= STRATOS_TARGET_REFRESH_DISTANCE * STRATOS_TARGET_REFRESH_DISTANCE
	var stratos_prefetch_changed := not _stratos_prefetch_focus.is_finite() \
		or _stratos_prefetch_focus.distance_squared_to(stratos_lead) \
			>= STRATOS_TARGET_REFRESH_DISTANCE * STRATOS_TARGET_REFRESH_DISTANCE
	var stratos_radius_changed := absf(current_view_distance
		- _stratos_target_radius) >= STRATOS_RADIUS_REFRESH_DISTANCE
	if stc != _stratos_center or predicted_stc != _stratos_prefetch_center \
			or ring != _stratos_ring or stratos_focus_changed \
			or stratos_prefetch_changed or stratos_radius_changed:
		_refresh_stratos_targets(stc, predicted_stc, ring, stratos_focus,
			stratos_lead)

	# Terrain shells, collision-critical completion, and visual decoration each
	# receive their own elapsed-time budget. A busy safety lane can no longer
	# consume every frame and indefinitely starve horizon/skyline tree silhouettes.
	_run_shell_work(cc, hc, sc, stc, ring)
	_sync_collision_queue()
	_run_safety_work(cc, predicted)
	_run_decorative_work()
	# Shell construction is bounded, so a descent handoff may become ready on any
	# frame. Retract successor coverage only after the just-built tier is complete.
	_update_altitude_lod_handoffs()
	_update_terrain_residency()


func _update_terrain_residency() -> void:
	var focus := _stream_focus_position()
	Visuals.set_terrain_residency(Vector2(focus.x, focus.z), chunks,
		horizon_chunks, skyline_chunks, stratos_chunks)


func _run_shell_work(cc: Vector2i, hc: Vector2i, sc: Vector2i,
		stc: Vector2i, ring: int) -> void:
	var started := Time.get_ticks_usec()
	var ops := 0
	var built_near := _build_one_near_shell(cc)
	if built_near:
		ops += 1
	# The predictive guard normally makes this zero. If a 1000 mph diagonal or
	# abrupt turn still exposes the current fine shell, complete that shell before
	# discretionary far work. At coarse-flight altitude the active guard is -1,
	# making this loop intentionally empty while the far tier owns the view.
	var current_guard_radius := _near_guard_radius()
	while ops < STREAM_SHELL_MAX_OPS \
			and _missing_square(chunks, cc, current_guard_radius) > 0:
		if not _build_one_near_shell(cc):
			break
		ops += 1
	# Do not blindly start another heavy mesh after the near shell has consumed
	# this frame's allowance. A one-frame anti-starvation deadline still gives the
	# far tiers at least 30 opportunities/s at a 60 Hz render rate.
	var far_waiting := not _horizon_queue.is_empty() or not _stratos_queue.is_empty() \
		or is_instance_valid(_active_stratos_sector) \
		or not _skyline_queue.is_empty()
	var can_build_far := not built_near \
		or Time.get_ticks_usec() - started < STREAM_SHELL_BUDGET_USEC \
		or _far_shell_defer_frames >= 1
	if far_waiting and can_build_far and ops < STREAM_SHELL_MAX_OPS:
		if _build_one_far_shell(hc, sc, stc, ring):
			ops += 1
			_far_shell_defer_frames = 0
	elif far_waiting:
		_far_shell_defer_frames += 1
	else:
		_far_shell_defer_frames = 0
	# Drain one additional prefetch shell when the measured lane has headroom.
	# This is what absorbs the nine-tile corner of a diagonal chunk crossing while
	# keeping the common frame bounded to one near plus one far-tier operation.
	if ops < STREAM_SHELL_MAX_OPS and not _queue.is_empty() \
			and (Time.get_ticks_usec() - started < STREAM_SHELL_BUDGET_USEC \
			or _literal_detail_suppressed):
		if _build_one_near_shell(cc):
			ops += 1
	_stream_shell_ops_last = ops
	_stream_shell_usec_last = Time.get_ticks_usec() - started


func _build_one_near_shell(_cc: Vector2i) -> bool:
	while not _queue.is_empty():
		var k: Vector2i = _queue.pop_front()
		_near_pending.erase(k)
		_near_enqueued_at.erase(k)
		if not _near_targets.has(k) or chunks.has(k):
			_stream_cancelled_jobs += 1
			continue
		_build_chunk(k, true)
		_stream_shells_built += 1
		return true
	return false


func _build_one_far_shell(hc: Vector2i, sc: Vector2i, stc: Vector2i,
		ring: int) -> bool:
	# A current inner-horizon hole is already player-visible and must not wait
	# behind a partially prefetched stratos row. The horizon queue is sorted with
	# this inner window first, so one build restores the most urgent missing tile.
	if not _horizon_foliage_suppressed and _missing_square(horizon_chunks, hc,
			maxi(Gen.HORIZON_VIEW_R - 1, 0)) > 0 \
			and _build_one_horizon_shell(hc):
		return true
	# Establish the current full far plane before spending work on predictive or
	# decorative bands. This priority is temporary (mainly initial warmup); once
	# complete, the 2 s predictive stratos row is served by the fair cycle below.
	if _has_missing_required_stratos() \
			and _build_one_stratos_shell(stc, ring):
		return true
	# A 192 m horizon row arrives much more often than the 768 m skyline or
	# 6144 m stratos rows at aircraft speed. Three weighted horizon turns followed
	# by one ultra-far turn meet that measured demand. Stratos consumes that fourth
	# turn only while predictive work exists; skyline receives every idle one.
	for attempt in range(4):
		var lane := _far_shell_lane % 4
		_far_shell_lane += 1
		if lane < 3 and not _horizon_foliage_suppressed:
			if _build_one_horizon_shell(hc):
				return true
		else:
			if _build_one_stratos_shell(stc, ring):
				return true
			if not _skyline_foliage_suppressed \
					and _build_one_skyline_shell(sc):
				return true
	return false


func _has_missing_required_stratos() -> bool:
	for k in _stratos_required_targets:
		if not stratos_chunks.has(k):
			return true
	return false


func _build_one_horizon_shell(_hc: Vector2i) -> bool:
	while not _horizon_queue.is_empty():
		var k: Vector2i = _horizon_queue.pop_front()
		_horizon_pending.erase(k)
		_horizon_enqueued_at.erase(k)
		if not _horizon_targets.has(k) or horizon_chunks.has(k):
			_stream_cancelled_jobs += 1
			continue
		_build_horizon_chunk(k, true)
		_stream_shells_built += 1
		return true
	return false


func _build_one_stratos_shell(_stc: Vector2i, _ring: int) -> bool:
	var row_budget := STRATOS_PREFLIGHT_ROW_BUDGET \
		if _stream_speed_mps < 1.0 else STRATOS_TERRAIN_ROW_BUDGET
	if is_instance_valid(_active_stratos_sector):
		if not _stratos_targets.has(_active_stratos_key):
			_active_stratos_sector.queue_free()
			_stratos_enqueued_at.erase(_active_stratos_key)
			_active_stratos_sector = null
			_active_stratos_key = Vector2i(0x3fffffff, 0x3fffffff)
			_active_stratos_started_usec = 0
			_stream_cancelled_jobs += 1
		else:
			var finished := _active_stratos_sector.build_terrain_step(
				row_budget)
			if finished:
				stratos_chunks[_active_stratos_key] = _active_stratos_sector
				_stratos_enqueued_at.erase(_active_stratos_key)
				_active_stratos_sector = null
				_active_stratos_key = Vector2i(0x3fffffff, 0x3fffffff)
				_active_stratos_started_usec = 0
				_stream_shells_built += 1
			return true
	while not _stratos_queue.is_empty():
		var k: Vector2i = _stratos_queue.pop_front()
		if not _stratos_targets.has(k) or stratos_chunks.has(k):
			_stratos_enqueued_at.erase(k)
			_stream_cancelled_jobs += 1
			continue
		var sector: StratosChunk = StratosChunkScript.new()
		add_child(sector)
		# The moving edge is tens of kilometres away and needs silhouette/color,
		# not a near-resolution 33x33 lattice. Half-resolution edge sectors share
		# the same boundary samples and cut their total generation cost 4x;
		# the current 3x3 retains the authored 192 m sampling.
		var delta := (k - _stc).abs()
		var cells := Gen.STRATOS_CELLS if maxi(delta.x, delta.y) <= 1 \
			else maxi(int(Gen.STRATOS_CELLS / 2), 8)
		sector.setup(k, cells, true)
		_active_stratos_sector = sector
		_active_stratos_key = k
		_active_stratos_started_usec = int(_stratos_enqueued_at.get(k,
			Time.get_ticks_usec()))
		var initial_finished := sector.build_terrain_step(
			row_budget)
		if initial_finished:
			stratos_chunks[k] = sector
			_stratos_enqueued_at.erase(k)
			_active_stratos_sector = null
			_active_stratos_key = Vector2i(0x3fffffff, 0x3fffffff)
			_active_stratos_started_usec = 0
			_stream_shells_built += 1
		return true
	return false


func _build_one_skyline_shell(sc: Vector2i) -> bool:
	while not _skyline_queue.is_empty():
		var k: Vector2i = _skyline_queue.pop_front()
		_skyline_pending.erase(k)
		_skyline_enqueued_at.erase(k)
		var delta := (k - sc).abs()
		if maxi(delta.x, delta.y) > Gen.SKYLINE_VIEW_R \
				or skyline_chunks.has(k):
			_stream_cancelled_jobs += 1
			continue
		_build_skyline_chunk(k)
		_stream_shells_built += 1
		return true
	return false


func _sync_collision_queue() -> void:
	for k in chunks:
		var chunk: Chunk = chunks[k]
		var wants_collision := _ground_collision_required \
			and _collision_targets.has(k)
		if wants_collision:
			if chunk.has_collisions():
				chunk.set_collision_active(true)
				_collision_queue.erase(chunk)
			elif not _collision_queue.has(chunk):
				_collision_queue.append(chunk)
		else:
			_collision_queue.erase(chunk)
			chunk.set_collision_active(false)


func _run_safety_work(cc: Vector2i, predicted: Vector2i) -> void:
	var started := Time.get_ticks_usec()
	var ops := 0
	_collision_queue.sort_custom(func(a: Chunk, b: Chunk):
		var a_current := Vector2(a.key - cc).length_squared()
		var b_current := Vector2(b.key - cc).length_squared()
		if is_equal_approx(a_current, b_current):
			return Vector2(a.key - predicted).length_squared() \
				< Vector2(b.key - predicted).length_squared()
		return a_current < b_current)
	while not _collision_queue.is_empty() and ops < STREAM_SAFETY_MAX_OPS:
		var chunk: Chunk = _collision_queue.pop_front()
		if not is_instance_valid(chunk) or not _ground_collision_required \
				or not _collision_targets.has(chunk.key):
			continue
		if chunk.has_collisions():
			chunk.set_collision_active(true)
		elif chunk.is_deferred_build_pending():
			var finished := chunk.finish_deferred_build_step()
			if finished:
				_register_chunk_bananas(chunk)
				chunk.remove_meta(STREAM_DETAIL_ENQUEUED_META)
			if chunk.has_collisions():
				chunk.set_collision_active(true)
			else:
				_collision_queue.append(chunk)
		else:
			# Chunks first prefetched outside the safety corridor intentionally skip
			# collision at setup. Build it now, after every authored prop exists.
			chunk.set_collision_active(true)
		ops += 1
		if Time.get_ticks_usec() - started >= STREAM_SAFETY_BUDGET_USEC:
			break
	_stream_safety_ops_last = ops
	_stream_safety_usec_last = Time.get_ticks_usec() - started


func _chunk_literal_detail_required(chunk: Chunk) -> bool:
	if not is_instance_valid(chunk) or _literal_detail_suppressed:
		return false
	return _chunk_in_window(chunk.key, center_chunk(), Gen.VIEW_R)


func _reconcile_chunk_detail_queue() -> void:
	var retained: Array[Chunk] = []
	for chunk in _chunk_detail_queue:
		if is_instance_valid(chunk) and chunk.is_deferred_build_pending() \
				and _chunk_literal_detail_required(chunk) and not retained.has(chunk):
			retained.append(chunk)
		else:
			if is_instance_valid(chunk):
				chunk.remove_meta(STREAM_DETAIL_ENQUEUED_META)
	_chunk_detail_queue = retained
	if _literal_detail_suppressed:
		return
	var now := Time.get_ticks_usec()
	for chunk_value in chunks.values():
		var chunk := chunk_value as Chunk
		if not _chunk_literal_detail_required(chunk) \
				or not chunk.is_deferred_build_pending() \
				or _chunk_detail_queue.has(chunk):
			continue
		chunk.set_meta(STREAM_DETAIL_ENQUEUED_META, now)
		_chunk_detail_queue.append(chunk)


func _run_decorative_work() -> void:
	var started := Time.get_ticks_usec()
	var ops := 0
	# Terrain is always published first. Do not spend a frame constructing foliage
	# over a missing visible shell, and suspend literal vegetation completely when
	# the camera is above its longest visibility range; stratos canopy tint owns
	# that aircraft view.
	var terrain_missing := _missing_visible_near_terrain(center_chunk(), Gen.VIEW_R) > 0 \
		or (not _horizon_foliage_suppressed \
		and _missing_square(horizon_chunks, center_horizon_sector(),
			maxi(Gen.HORIZON_VIEW_R - 1, 0)) > 0) \
		or (not _skyline_foliage_suppressed \
		and _missing_square(skyline_chunks, center_skyline_sector(),
			maxi(Gen.SKYLINE_VIEW_R - 1, 0)) > 0) \
		or _has_missing_required_stratos()
	if terrain_missing:
		_stream_decoration_ops_last = 0
		_stream_decoration_usec_last = Time.get_ticks_usec() - started
		return
	# Finish current playable detail before spending the first slice on distant
	# silhouettes. Every far-tree node already owns a terrain parent shell.
	if not _literal_detail_suppressed and _build_one_near_detail_step():
		ops += 1
	elif _build_one_far_tree_step():
		ops += 1
	while ops < STREAM_DECORATION_MAX_OPS \
			and Time.get_ticks_usec() - started < STREAM_DECORATION_BUDGET_USEC:
		var prefer_near := (_decoration_lane % 3) != 2
		_decoration_lane += 1
		var built := _build_one_near_detail_step() if prefer_near \
			else _build_one_far_tree_step()
		if not built:
			built = _build_one_far_tree_step() if prefer_near \
				else _build_one_near_detail_step()
		if not built:
			break
		ops += 1
	_stream_decoration_ops_last = ops
	_stream_decoration_usec_last = Time.get_ticks_usec() - started


func _build_one_near_detail_step() -> bool:
	while not _chunk_detail_queue.is_empty():
		var chunk: Chunk = _chunk_detail_queue.pop_front()
		if not is_instance_valid(chunk) or not chunk.is_deferred_build_pending() \
				or not _chunk_literal_detail_required(chunk):
			if is_instance_valid(chunk):
				chunk.remove_meta(STREAM_DETAIL_ENQUEUED_META)
			continue
		var finished := chunk.finish_deferred_build_step()
		if finished:
			_register_chunk_bananas(chunk)
			chunk.remove_meta(STREAM_DETAIL_ENQUEUED_META)
		else:
			_chunk_detail_queue.append(chunk)
		return true
	return false


func _build_one_far_tree_step() -> bool:
	for attempt in range(2):
		var lane := _far_tree_lane % 2
		_far_tree_lane += 1
		if lane == 0:
			if _horizon_foliage_suppressed:
				continue
			while not _horizon_detail_queue.is_empty():
				var sector: HorizonChunk = _horizon_detail_queue.front()
				if not is_instance_valid(sector) or sector.is_queued_for_deletion():
					_horizon_detail_queue.pop_front()
					continue
				var source_budget := HORIZON_TREE_SOURCE_BUDGET_FAST \
					if _stream_speed_mps >= STREAM_FAST_SPEED \
					else HORIZON_TREE_SOURCE_BUDGET
				if sector.build_tree_step(source_budget):
					_horizon_detail_queue.pop_front()
					sector.remove_meta(STREAM_DETAIL_ENQUEUED_META)
				return true
		else:
			if _skyline_foliage_suppressed:
				continue
			while not _skyline_detail_queue.is_empty():
				var sector: SkylineChunk = _skyline_detail_queue.front()
				if not is_instance_valid(sector) or sector.is_queued_for_deletion():
					_skyline_detail_queue.pop_front()
					continue
				var source_budget := SKYLINE_TREE_SOURCE_BUDGET_FAST \
					if _stream_speed_mps >= STREAM_FAST_SPEED \
					else SKYLINE_TREE_SOURCE_BUDGET
				if sector.build_tree_step(source_budget):
					_skyline_detail_queue.pop_front()
					sector.remove_meta(STREAM_DETAIL_ENQUEUED_META)
				return true
	return false


func center_horizon_sector() -> Vector2i:
	var c := _stream_focus_position()
	var sector_size := Gen.CHUNK * Gen.HORIZON_SECTOR_CHUNKS
	return Vector2i(floori(c.x / sector_size), floori(c.z / sector_size))


func center_skyline_sector() -> Vector2i:
	var c := _stream_focus_position()
	var sector_size := Gen.CHUNK * Gen.SKYLINE_SECTOR_CHUNKS
	return Vector2i(floori(c.x / sector_size), floori(c.z / sector_size))


func _predicted_near_center(cc: Vector2i) -> Vector2i:
	if not local_player or _expedition_stream_focus.is_finite():
		return cc
	var lead := local_player.global_position \
		+ local_player.velocity * NEAR_PREDICTION_TIME
	var raw := Vector2i(floori(lead.x / Gen.CHUNK),
		floori(lead.z / Gen.CHUNK))
	var offset := Vector2(raw - cc)
	if offset.length() > NEAR_PREDICTION_MAX_CHUNKS:
		offset = offset.normalized() * NEAR_PREDICTION_MAX_CHUNKS
	return cc + Vector2i(roundi(offset.x), roundi(offset.y))


func _chunk_in_window(k: Vector2i, center: Vector2i, radius: int) -> bool:
	var delta := (k - center).abs()
	return maxi(delta.x, delta.y) <= radius


func _near_guard_radius() -> int:
	# At ground/low flight the 108 m horizon handoff needs a complete 5x5. Once
	# that tier is vertically invisible and no collision floor is required, its
	# canopy-aware successor fully owns the view beneath the aircraft. A negative
	# radius deliberately means there is no local fine-terrain guard to stream.
	return -1 if _horizon_foliage_suppressed \
		and not _ground_collision_required else Gen.VIEW_R


func _swept_near_centers(cc: Vector2i, predicted: Vector2i) -> Array[Vector2i]:
	var centers: Array[Vector2i] = []
	var delta := predicted - cc
	var steps := maxi(absi(delta.x), absi(delta.y))
	if steps <= 0:
		centers.append(cc)
		return centers
	for i in range(steps + 1):
		var alpha := float(i) / float(steps)
		var center := Vector2i(roundi(lerpf(float(cc.x), float(predicted.x), alpha)),
			roundi(lerpf(float(cc.y), float(predicted.y), alpha)))
		if centers.is_empty() or centers[-1] != center:
			centers.append(center)
	return centers


func _add_target_window(targets: Dictionary, target_center: Vector2i,
		radius: int) -> void:
	for dx in range(-radius, radius + 1):
		for dz in range(-radius, radius + 1):
			targets[target_center + Vector2i(dx, dz)] = true


func _refresh_collision_targets(cc: Vector2i, predicted: Vector2i) -> bool:
	var next_targets: Dictionary = {}
	if _local_collision_required:
		# Full room to manoeuvre around the player, then a narrow swept centerline
		# farther ahead. Descending aircraft receive this corridor before impact.
		_add_target_window(next_targets, cc, 1)
		for center in _swept_near_centers(cc, predicted):
			next_targets[center] = true
	# Keep floors beneath nearby AI/remote monkeys even while the local pilot is
	# high enough that its own collision corridor can safely sleep. The spatial
	# range gate makes this dictionary finite; the explicit cap is a final guard if
	# future actor sources bypass that gate.
	var actor_targets: Dictionary = {}
	for actor_center in _ground_actor_collision_centers:
		_add_target_window(actor_targets, actor_center,
			GROUND_ACTOR_COLLISION_PATCH_RADIUS)
	var actor_keys: Array = actor_targets.keys()
	if actor_keys.size() > GROUND_ACTOR_COLLISION_SHELL_TARGET_LIMIT:
		actor_keys.sort_custom(func(a, b):
			var distance_a := Vector2(a - cc).length_squared()
			var distance_b := Vector2(b - cc).length_squared()
			if is_equal_approx(distance_a, distance_b):
				return a.x < b.x if a.x != b.x else a.y < b.y
			return distance_a < distance_b)
		actor_keys.resize(GROUND_ACTOR_COLLISION_SHELL_TARGET_LIMIT)
	_actor_collision_targets.clear()
	for key in actor_keys:
		_actor_collision_targets[key] = true
		next_targets[key] = true
	var changed := next_targets != _collision_targets
	_collision_targets = next_targets
	return changed


func _refresh_near_targets(cc: Vector2i, predicted: Vector2i) -> void:
	_stream_center = cc
	_prefetch_center = predicted
	var previous_times := _near_enqueued_at.duplicate()
	_near_targets.clear()
	var current_guard_radius := _near_guard_radius()
	_near_guard_radius_state = current_guard_radius
	# Keep the full gameplay shell and predictive corridor whenever near terrain is
	# visible or collision-critical. At high altitude the -1 sentinel skips this
	# redundant tier; the skyline/stratos shell already covers the camera nadir.
	if current_guard_radius >= 0:
		_add_target_window(_near_targets, cc, current_guard_radius)
		# Ahead of the guard, stream a swept corridor rather than another full square
		# only at the endpoint. The immediate next center matches the current shell
		# width so its corners are ready; the remaining ~0.85 s path is only three wide.
		var swept := _swept_near_centers(cc, predicted)
		for i in range(1, swept.size()):
			var corridor_radius := current_guard_radius if i == 1 else 1
			_add_target_window(_near_targets, swept[i], corridor_radius)
	# Collision work cannot build a floor without a near terrain shell. Actor
	# patches are capped above, so merging them preserves the bounded scheduler and
	# its existing per-frame operation/time ceilings.
	for k in _collision_targets:
		_near_targets[k] = true
	_queue.clear()
	_near_pending.clear()
	_near_enqueued_at.clear()
	var now := Time.get_ticks_usec()
	for k in _near_targets:
		if not chunks.has(k):
			_queue.append(k)
			_near_pending[k] = true
			_near_enqueued_at[k] = int(previous_times.get(k, now))
	for old_k in previous_times:
		if not _near_enqueued_at.has(old_k):
			_stream_cancelled_jobs += 1
	_queue.sort_custom(func(a, b):
		var actual_a := _chunk_in_window(a, cc, Gen.VIEW_R)
		var actual_b := _chunk_in_window(b, cc, Gen.VIEW_R)
		if actual_a != actual_b:
			return actual_a
		var collision_a := _collision_targets.has(a)
		var collision_b := _collision_targets.has(b)
		if collision_a != collision_b:
			return collision_a
		# For predictive terrain the next current-row corners are more urgent than
		# an older tile seven chunks down the flight path. Distance precedes age;
		# retained timestamps still settle ties without starving a fixed location.
		var distance_a := Vector2(a - cc).length_squared()
		var distance_b := Vector2(b - cc).length_squared()
		if not is_equal_approx(distance_a, distance_b):
			return distance_a < distance_b
		var predicted_distance_a := Vector2(a - predicted).length_squared()
		var predicted_distance_b := Vector2(b - predicted).length_squared()
		if not is_equal_approx(predicted_distance_a, predicted_distance_b):
			return predicted_distance_a < predicted_distance_b
		var enqueued_a := int(_near_enqueued_at.get(a, now))
		var enqueued_b := int(_near_enqueued_at.get(b, now))
		if enqueued_a != enqueued_b:
			return enqueued_a < enqueued_b
		return a.x < b.x if a.x != b.x else a.y < b.y)

	var dead: Array = []
	for k in chunks:
		if not _near_targets.has(k):
			dead.append(k)
	for k in dead:
		var chunk: Chunk = chunks[k]
		_collision_queue.erase(chunk)
		_chunk_detail_queue.erase(chunk)
		for child in chunk.get_children():
			if child is Banana:
				_banana_nodes.erase(child.id)
			elif child is SupplyHut:
				unregister_supply_hut(child)
		chunk.queue_free()
		chunks.erase(k)
	_retire_streamed_wilderness_vehicles()
	_reconcile_chunk_detail_queue()


func _refresh_horizon_targets(hc: Vector2i, predicted_hc: Vector2i) -> void:
	_horizon_center = hc
	_horizon_prefetch_center = predicted_hc
	var previous_times := _horizon_enqueued_at.duplicate()
	_horizon_targets.clear()
	_add_target_window(_horizon_targets, hc, Gen.HORIZON_VIEW_R)
	if predicted_hc != hc:
		_add_target_window(_horizon_targets, predicted_hc, Gen.HORIZON_VIEW_R)
	_horizon_queue.clear()
	_horizon_pending.clear()
	_horizon_enqueued_at.clear()
	var now := Time.get_ticks_usec()
	for k in _horizon_targets:
		if not horizon_chunks.has(k):
			_horizon_queue.append(k)
			_horizon_pending[k] = true
			_horizon_enqueued_at[k] = int(previous_times.get(k, now))
	for old_k in previous_times:
		if not _horizon_enqueued_at.has(old_k):
			_stream_cancelled_jobs += 1
	_horizon_queue.sort_custom(func(a, b):
		var inner_a := _chunk_in_window(a, hc,
			maxi(Gen.HORIZON_VIEW_R - 1, 0))
		var inner_b := _chunk_in_window(b, hc,
			maxi(Gen.HORIZON_VIEW_R - 1, 0))
		if inner_a != inner_b:
			return inner_a
		var current_a := _chunk_in_window(a, hc, Gen.HORIZON_VIEW_R)
		var current_b := _chunk_in_window(b, hc, Gen.HORIZON_VIEW_R)
		if current_a != current_b:
			return current_a
		var distance_a := Vector2(a - predicted_hc).length_squared()
		var distance_b := Vector2(b - predicted_hc).length_squared()
		if not is_equal_approx(distance_a, distance_b):
			return distance_a < distance_b
		var enqueued_a := int(_horizon_enqueued_at.get(a, now))
		var enqueued_b := int(_horizon_enqueued_at.get(b, now))
		if enqueued_a != enqueued_b:
			return enqueued_a < enqueued_b
		return a.x < b.x if a.x != b.x else a.y < b.y)
	var dead: Array = []
	for k in horizon_chunks:
		if not _horizon_targets.has(k):
			dead.append(k)
	for k in dead:
		var sector: HorizonChunk = horizon_chunks[k]
		_horizon_detail_queue.erase(sector)
		sector.queue_free()
		horizon_chunks.erase(k)


func _suspend_horizon_stream() -> void:
	for sector_value in horizon_chunks.values():
		if is_instance_valid(sector_value):
			sector_value.queue_free()
	horizon_chunks.clear()
	_horizon_detail_queue.clear()
	_horizon_queue.clear()
	_horizon_pending.clear()
	_horizon_targets.clear()
	_horizon_enqueued_at.clear()
	_horizon_center = Vector2i(0x3fffffff, 0x3fffffff)
	_horizon_prefetch_center = _horizon_center


func _refresh_stratos_targets(stc: Vector2i, predicted_stc: Vector2i,
		ring: int, focus_xz: Vector2, predicted_focus_xz: Vector2) -> void:
	_stratos_center = stc
	_stratos_prefetch_center = predicted_stc
	_stratos_ring = ring
	_stratos_target_focus = focus_xz
	_stratos_prefetch_focus = predicted_focus_xz
	_stratos_target_radius = current_view_distance
	var previous_times := _stratos_enqueued_at.duplicate()
	_stratos_required_targets = circular_stratos_targets(focus_xz,
		current_view_distance)
	_stratos_targets.clear()
	for k in _stratos_required_targets:
		_stratos_targets[k] = true
	if predicted_focus_xz.distance_squared_to(focus_xz) \
			>= STRATOS_TARGET_REFRESH_DISTANCE * STRATOS_TARGET_REFRESH_DISTANCE:
		var predicted_targets := circular_stratos_targets(predicted_focus_xz,
			current_view_distance)
		for k in predicted_targets:
			_stratos_targets[k] = true
	if is_instance_valid(_active_stratos_sector) \
			and not _stratos_targets.has(_active_stratos_key):
		_active_stratos_sector.queue_free()
		_active_stratos_sector = null
		_stratos_enqueued_at.erase(_active_stratos_key)
		_active_stratos_key = Vector2i(0x3fffffff, 0x3fffffff)
		_active_stratos_started_usec = 0
		_stream_cancelled_jobs += 1
	_stratos_queue.clear()
	_stratos_enqueued_at.clear()
	var now := Time.get_ticks_usec()
	for k in _stratos_targets:
		if is_instance_valid(_active_stratos_sector) and k == _active_stratos_key:
			_stratos_enqueued_at[k] = int(previous_times.get(k,
				_active_stratos_started_usec if _active_stratos_started_usec > 0 \
				else now))
			continue
		if not stratos_chunks.has(k):
			_stratos_queue.append(k)
			_stratos_enqueued_at[k] = int(previous_times.get(k, now))
	for old_k in previous_times:
		if not _stratos_enqueued_at.has(old_k):
			_stream_cancelled_jobs += 1
	_stratos_queue.sort_custom(func(a, b):
		var required_a := _stratos_required_targets.has(a)
		var required_b := _stratos_required_targets.has(b)
		if required_a != required_b:
			return required_a
		var distance_a := Vector2(a - predicted_stc).length_squared()
		var distance_b := Vector2(b - predicted_stc).length_squared()
		if not is_equal_approx(distance_a, distance_b):
			return distance_a < distance_b
		var enqueued_a := int(_stratos_enqueued_at.get(a, now))
		var enqueued_b := int(_stratos_enqueued_at.get(b, now))
		if enqueued_a != enqueued_b:
			return enqueued_a < enqueued_b
		return a.x < b.x if a.x != b.x else a.y < b.y)
	var dead: Array = []
	for k in stratos_chunks:
		if not _stratos_targets.has(k):
			dead.append(k)
	for k in dead:
		stratos_chunks[k].queue_free()
		stratos_chunks.erase(k)


func _refresh_skyline_targets(sc: Vector2i) -> void:
	_skyline_center = sc
	var previous_times := _skyline_enqueued_at.duplicate()
	_skyline_queue.clear()
	_skyline_pending.clear()
	_skyline_enqueued_at.clear()
	var now := Time.get_ticks_usec()
	for dx in range(-Gen.SKYLINE_VIEW_R, Gen.SKYLINE_VIEW_R + 1):
		for dz in range(-Gen.SKYLINE_VIEW_R, Gen.SKYLINE_VIEW_R + 1):
			var k := sc + Vector2i(dx, dz)
			if not skyline_chunks.has(k):
				_skyline_queue.append(k)
				_skyline_pending[k] = true
				_skyline_enqueued_at[k] = int(previous_times.get(k, now))
	for old_k in previous_times:
		if not _skyline_enqueued_at.has(old_k):
			_stream_cancelled_jobs += 1
	_skyline_queue.sort_custom(func(a, b):
		var distance_a := Vector2(a - sc).length_squared()
		var distance_b := Vector2(b - sc).length_squared()
		if not is_equal_approx(distance_a, distance_b):
			return distance_a < distance_b
		var enqueued_a := int(_skyline_enqueued_at.get(a, now))
		var enqueued_b := int(_skyline_enqueued_at.get(b, now))
		if enqueued_a != enqueued_b:
			return enqueued_a < enqueued_b
		return a.x < b.x if a.x != b.x else a.y < b.y)
	var dead: Array = []
	for k in skyline_chunks:
		var d: Vector2i = (k - sc).abs()
		if maxi(d.x, d.y) > Gen.SKYLINE_DROP_R:
			dead.append(k)
	for k in dead:
		_skyline_detail_queue.erase(skyline_chunks[k])
		skyline_chunks[k].queue_free()
		skyline_chunks.erase(k)


func _suspend_skyline_stream() -> void:
	for sector_value in skyline_chunks.values():
		if is_instance_valid(sector_value):
			sector_value.queue_free()
	skyline_chunks.clear()
	_skyline_detail_queue.clear()
	_skyline_queue.clear()
	_skyline_pending.clear()
	_skyline_enqueued_at.clear()
	_skyline_center = Vector2i(0x3fffffff, 0x3fffffff)


func _build_skyline_chunk(k: Vector2i) -> void:
	var sector: SkylineChunk = SkylineChunkScript.new()
	add_child(sector)
	sector.setup(k, true)
	sector.set_literal_foliage_visible(not _skyline_foliage_suppressed)
	skyline_chunks[k] = sector
	sector.set_meta(STREAM_DETAIL_ENQUEUED_META, Time.get_ticks_usec())
	_skyline_detail_queue.append(sector)


func _build_chunk(k: Vector2i, defer_outer_details := true) -> void:
	var c := Chunk.new()
	add_child(c)
	var needs_collision := _collision_targets.has(k)
	# Runtime streaming publishes terrain shells first even in the safety ring.
	# Detail and collision construction then use bounded per-frame stages; the
	# player cannot traverse the 48 m center chunk before that ring is completed.
	var defer_details := defer_outer_details
	var coarse_terrain := _literal_detail_suppressed and not needs_collision
	c.setup(k, Net.collected, needs_collision, defer_details, coarse_terrain)
	chunks[k] = c
	c.set_literal_foliage_visible(not _literal_detail_suppressed)
	if defer_details:
		if _chunk_literal_detail_required(c):
			c.set_meta(STREAM_DETAIL_ENQUEUED_META, Time.get_ticks_usec())
			_chunk_detail_queue.append(c)
	else:
		_register_chunk_bananas(c)


func _register_chunk_bananas(chunk: Chunk) -> void:
	if not is_instance_valid(chunk):
		return
	for child in chunk.get_children():
		if child is Banana:
			register_banana(child)


## Synchronous startup is the one path allowed to finish a shell outside the
## per-frame lanes. Collision is explicit because no local player exists yet to
## populate `_collision_targets`; runtime/high-altitude shells keep using that
## bounded target set exclusively.
func _warm_chunk(k: Vector2i, require_collision: bool) -> void:
	var chunk := chunks.get(k) as Chunk
	if chunk == null:
		_build_chunk(k, false)
		chunk = chunks.get(k) as Chunk
	elif chunk.is_deferred_build_pending():
		chunk.finish_deferred_build()
		_chunk_detail_queue.erase(chunk)
		chunk.remove_meta(STREAM_DETAIL_ENQUEUED_META)
		_register_chunk_bananas(chunk)
	if chunk != null and require_collision:
		chunk.set_collision_active(true)
		_collision_queue.erase(chunk)


func _build_horizon_chunk(k: Vector2i, defer_trees := true) -> void:
	var sector = HorizonChunkScript.new()
	add_child(sector)
	sector.setup(k, defer_trees)
	sector.set_literal_foliage_visible(not _horizon_foliage_suppressed)
	horizon_chunks[k] = sector
	if defer_trees:
		sector.set_meta(STREAM_DETAIL_ENQUEUED_META, Time.get_ticks_usec())
		_horizon_detail_queue.append(sector)


func warm(radius: int) -> void:
	var cc := center_chunk()
	for dx in range(-radius, radius + 1):
		for dz in range(-radius, radius + 1):
			var k := cc + Vector2i(dx, dz)
			# Match the original startup floor: the central 3x3 is immediately
			# playable while an outer warm ring remains visual-only.
			_warm_chunk(k, maxi(absi(dx), absi(dz)) <= 1)
	# Nine coarse sectors provide an immediate 288 m+ backdrop. The remaining
	# sectors stream over subsequent frames without blocking world entry.
	var hc := center_horizon_sector()
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			var hk := hc + Vector2i(dx, dz)
			if not horizon_chunks.has(hk):
				_build_horizon_chunk(hk, false)
	# Nine skyline sectors put the mountain ranges on screen from the first
	# frame (±1.15 km); the outer ring streams in on idle frames.
	var sc := center_skyline_sector()
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			var sk := sc + Vector2i(dx, dz)
			if not skyline_chunks.has(sk):
				_build_skyline_chunk(sk)
	_update_terrain_residency()


## Fast online entry: publish one fully playable chunk — the one under the
## joining peer's jittered spawn spot, which the ID jitter can push outside
## the origin chunk — and let the elapsed-time streaming lanes fill the
## surrounding jungle after the player is visible. Solo/test warm() keeps its
## deterministic full-radius semantics.
func warm_online_entry(peer_id := 1) -> void:
	var pos := spawn_position(peer_id)
	var cc := Vector2i(floori(pos.x / Gen.CHUNK), floori(pos.z / Gen.CHUNK))
	_warm_chunk(cc, true)
	_update_terrain_residency()


func _missing_square(loaded: Dictionary, center: Vector2i, radius: int) -> int:
	if radius < 0:
		return 0
	var missing := 0
	for dx in range(-radius, radius + 1):
		for dz in range(-radius, radius + 1):
			if not loaded.has(center + Vector2i(dx, dz)):
				missing += 1
	return missing


## Report the active near-shell contract rather than assuming every dormant
## gameplay tile must exist. Ground/low flight calls this for 5x5; high flight
## passes -1 after the canopy-aware far tier takes complete ownership.
## `near_detail_missing` separately keeps the dormant full 5x5 measurable.
func _missing_visible_near_terrain(center: Vector2i, radius: int) -> int:
	if radius < 0:
		return 0
	var missing := 0
	for dx in range(-radius, radius + 1):
		for dz in range(-radius, radius + 1):
			var chunk_key := center + Vector2i(dx, dz)
			if chunks.has(chunk_key):
				continue
			var horizon_key := Vector2i(
				floori(float(chunk_key.x) / float(Gen.HORIZON_SECTOR_CHUNKS)),
				floori(float(chunk_key.y) / float(Gen.HORIZON_SECTOR_CHUNKS)))
			var horizon = horizon_chunks.get(horizon_key)
			if is_instance_valid(horizon) \
					and horizon.get_node_or_null("CoarseTerrain") != null:
				continue
			missing += 1
	return missing


func _oldest_key_queue_ms(queue: Array, enqueued_at: Dictionary,
		now_usec: int) -> float:
	var oldest := now_usec
	var found := false
	for key in queue:
		if not enqueued_at.has(key):
			continue
		oldest = mini(oldest, int(enqueued_at[key]))
		found = true
	return float(now_usec - oldest) / 1000.0 if found else 0.0


func _oldest_node_queue_ms(queue: Array, now_usec: int) -> float:
	var oldest := now_usec
	var found := false
	for node in queue:
		if not is_instance_valid(node) or not node.has_meta(STREAM_DETAIL_ENQUEUED_META):
			continue
		oldest = mini(oldest, int(node.get_meta(STREAM_DETAIL_ENQUEUED_META)))
		found = true
	return float(now_usec - oldest) / 1000.0 if found else 0.0


## Stable public diagnostics for rendered traversal benchmarks. The metrics are
## intentionally hardware-independent: they expose coverage holes, work age,
## prediction lead, and bounded queue sizes rather than inferring health from FPS.
func streaming_snapshot() -> Dictionary:
	var now := Time.get_ticks_usec()
	var cc := center_chunk()
	var hc := center_horizon_sector()
	var sc := center_skyline_sector()
	var collision_missing := 0
	if _ground_collision_required:
		for k in _collision_targets:
			if not chunks.has(k) or not (chunks[k] as Chunk).has_collisions():
				collision_missing += 1
	var stratos_required_missing := 0
	var stratos_required_loaded := 0
	var stratos_canopy_vertices := 0
	var stratos_canopy_sectors := 0
	var stratos_canopy_geometry_sectors := 0
	var stratos_canopy_not_applicable_sectors := 0
	for k in _stratos_required_targets:
		var sector_value = stratos_chunks.get(k)
		if not is_instance_valid(sector_value):
			stratos_required_missing += 1
			continue
		stratos_required_loaded += 1
		var canopy_vertices := int(sector_value.canopy_vertex_count)
		stratos_canopy_vertices += canopy_vertices
		if canopy_vertices > 0:
			stratos_canopy_geometry_sectors += 1
			stratos_canopy_sectors += 1
		# Planet biomes legitimately contain ocean, ice and arid stratos sectors
		# with no forest-cover vertices. setup() builds StratosTerrain synchronously,
		# so a completed terrain mesh makes canopy coverage not applicable rather
		# than missing. Keep actual geometry separate and require it elsewhere via
		# stratos_canopy_vertices; required-sector loading remains an independent
		# full-coverage metric.
		elif sector_value.get_node_or_null("StratosTerrain") != null:
			stratos_canopy_not_applicable_sectors += 1
			stratos_canopy_sectors += 1
	var stratos_square_capacity := 0
	if _stratos_ring >= 0:
		stratos_square_capacity = (2 * _stratos_ring + 1) \
			* (2 * _stratos_ring + 1)
	var stratos_culled_corners := maxi(stratos_square_capacity
		- _stratos_required_targets.size(), 0)
	var streamed_unprotected_vehicles := 0
	for vid_value in _streamed_vehicle_sources.keys():
		var vid := str(vid_value)
		var candidate = vehicles.get(vid)
		if is_instance_valid(candidate) \
				and not _streamed_vehicle_is_protected(vid, candidate as Vehicle):
			streamed_unprotected_vehicles += 1
	var vehicle_node_count := 0
	for child in get_children():
		if child is Vehicle:
			vehicle_node_count += 1
	var coarse_near_shells := 0
	for chunk_value in chunks.values():
		var chunk := chunk_value as Chunk
		if is_instance_valid(chunk) and chunk.is_coarse_terrain_shell():
			coarse_near_shells += 1
	var near_detail_age := 0.0 if _literal_detail_suppressed else \
		_oldest_node_queue_ms(_chunk_detail_queue, now)
	var horizon_tree_age := 0.0 if _horizon_foliage_suppressed else \
		_oldest_node_queue_ms(_horizon_detail_queue, now)
	var skyline_tree_age := 0.0 if _skyline_foliage_suppressed else \
		_oldest_node_queue_ms(_skyline_detail_queue, now)
	var shell_age := maxf(
		_oldest_key_queue_ms(_queue, _near_enqueued_at, now),
		maxf(_oldest_key_queue_ms(_horizon_queue, _horizon_enqueued_at, now),
		maxf(_oldest_key_queue_ms(_skyline_queue, _skyline_enqueued_at, now),
			_oldest_key_queue_ms(_stratos_queue, _stratos_enqueued_at, now))))
	if is_instance_valid(_active_stratos_sector) \
			and _active_stratos_started_usec > 0:
		shell_age = maxf(shell_age,
			float(now - _active_stratos_started_usec) / 1000.0)
	var active_near_detail := 0 if _literal_detail_suppressed else \
		_chunk_detail_queue.size()
	var active_horizon_trees := 0 if _horizon_foliage_suppressed else \
		_horizon_detail_queue.size()
	var active_skyline_trees := 0 if _skyline_foliage_suppressed else \
		_skyline_detail_queue.size()
	var total_pending := _queue.size() + _horizon_queue.size() \
		+ _skyline_queue.size() + _stratos_queue.size() \
		+ (1 if is_instance_valid(_active_stratos_sector) else 0) \
		+ active_near_detail + active_horizon_trees \
		+ active_skyline_trees + _collision_queue.size()
	var prediction_lead := Vector2(_prefetch_center - _stream_center).length() \
		* Gen.CHUNK
	var live_stratos_focus := Vector2.ZERO
	if local_player:
		live_stratos_focus = Vector2(local_player.global_position.x,
			local_player.global_position.z)
	var stratos_cardinal_coverage := loaded_stratos_edge_coverage(
		stratos_chunks, live_stratos_focus, current_view_distance, 4)
	var stratos_radial_coverage := loaded_stratos_edge_coverage(
		stratos_chunks, live_stratos_focus, current_view_distance, 16)
	return {
		"speed_mps": _stream_speed_mps,
		"ground_clearance_m": _local_ground_clearance,
		"view_distance_m": current_view_distance,
		"prediction_lead_m": prediction_lead,
		"prediction_lead_s": prediction_lead / maxf(_stream_speed_mps, 0.001),
		"ground_collision_required": _ground_collision_required,
		"local_collision_required": _local_collision_required,
		"literal_detail_suppressed": _literal_detail_suppressed,
		"horizon_foliage_suppressed": _horizon_foliage_suppressed,
		"skyline_foliage_suppressed": _skyline_foliage_suppressed,
		"horizon_handoff_ready": _horizon_handoff_ready,
		"skyline_handoff_ready": _skyline_handoff_ready,
		"horizon_tier_suppressed": _horizon_foliage_suppressed,
		"skyline_tier_suppressed": _skyline_foliage_suppressed,
		"canopy_signal_tier": "stratos_tint" if not _skyline_handoff_ready \
			else ("skyline_tint" if not _horizon_handoff_ready \
			else "literal_handoff"),
		"tracked_ground_vehicles": _tracked_ground_vehicle_count,
		"actor_collision_targets": _actor_collision_targets.size(),
		"actor_collision_target_limit": GROUND_ACTOR_COLLISION_SHELL_TARGET_LIMIT,
		"collision_targets": _collision_targets.size(),
		"near_targets": _near_targets.size(),
		"near_queue": _queue.size(),
		"horizon_queue": _horizon_queue.size(),
		"skyline_queue": _skyline_queue.size(),
		"stratos_queue": _stratos_queue.size() \
			+ (1 if is_instance_valid(_active_stratos_sector) else 0),
		"collision_queue": _collision_queue.size(),
		"near_detail_queue": active_near_detail,
		"horizon_tree_queue": active_horizon_trees,
		"skyline_tree_queue": active_skyline_trees,
		"near_detail_suspended": _chunk_detail_queue.size() - active_near_detail,
		"horizon_tree_suspended": _horizon_detail_queue.size()
			- active_horizon_trees,
		"skyline_tree_suspended": _skyline_detail_queue.size()
			- active_skyline_trees,
		"total_pending": total_pending,
		"shell_oldest_ms": shell_age,
		"near_detail_oldest_ms": near_detail_age,
		"far_tree_oldest_ms": maxf(horizon_tree_age, skyline_tree_age),
		"near_path_missing": 0 if _near_guard_radius() < 0 else \
			_missing_square(chunks, cc, 1),
		"near_current_missing": _missing_visible_near_terrain(cc,
			_near_guard_radius()),
		"near_detail_missing": _missing_square(chunks, cc, Gen.VIEW_R),
		"coarse_near_shells": coarse_near_shells,
		"horizon_inner_missing": 0 if _horizon_foliage_suppressed else \
			_missing_square(horizon_chunks, hc,
				maxi(Gen.HORIZON_VIEW_R - 1, 0)),
		"skyline_inner_missing": 0 if _skyline_foliage_suppressed else \
			_missing_square(skyline_chunks, sc,
				maxi(Gen.SKYLINE_VIEW_R - 1, 0)),
		"stratos_required": _stratos_required_targets.size(),
		"stratos_required_loaded": stratos_required_loaded,
		"stratos_required_missing": stratos_required_missing,
		"stratos_square_capacity": stratos_square_capacity,
		"stratos_culled_corner_targets": stratos_culled_corners,
		"stratos_cardinal_coverage_m": stratos_cardinal_coverage,
		"stratos_radial_coverage_m": stratos_radial_coverage,
		"collision_corridor_missing": collision_missing,
		"stratos_canopy_sectors": stratos_canopy_sectors,
		"stratos_canopy_geometry_sectors": stratos_canopy_geometry_sectors,
		"stratos_canopy_not_applicable_sectors": \
			stratos_canopy_not_applicable_sectors,
		"stratos_canopy_vertices": stratos_canopy_vertices,
		"streamed_wilderness_vehicles": _streamed_vehicle_sources.size(),
		"streamed_unprotected_vehicles": streamed_unprotected_vehicles,
		"retained_wilderness_vehicles": _retained_wilderness_vehicle_ids.size(),
		"spawned_vehicle_ids": _spawned_vehicle_ids.size(),
		"vehicle_nodes": vehicle_node_count,
		"vehicle_registry": vehicles.size(),
		"shell_usec": _stream_shell_usec_last,
		"safety_usec": _stream_safety_usec_last,
		"decoration_usec": _stream_decoration_usec_last,
		"shell_ops": _stream_shell_ops_last,
		"safety_ops": _stream_safety_ops_last,
		"decoration_ops": _stream_decoration_ops_last,
		"shells_built": _stream_shells_built,
		"cancelled_jobs": _stream_cancelled_jobs,
	}


func reset_streaming_metrics() -> void:
	_stream_shells_built = 0
	_stream_cancelled_jobs = 0


# ---- test scaffolding ------------------------------------------------------

func add_debug_vine(anchor: Vector3, vlen: float) -> String:
	return Gen.add_debug_vine(anchor, vlen)


func add_debug_wall(pos: Vector3, size: Vector3) -> void:
	var body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	cs.shape = box
	body.add_child(cs)
	add_child(body)
	body.global_position = pos


func add_debug_banana(pos: Vector3, id: String) -> void:
	var b := Banana.new()
	b.setup(id, pos)
	add_child(b)
	register_banana(b)


static func space_sky_weight_for_altitude(altitude: float) -> float:
	return smoothstep(SPACE_SKY_START_ALTITUDE,SPACE_SKY_FULL_ALTITUDE,altitude)


func _apply_altitude_sky(altitude: float) -> void:
	if not _environment or Net.player_realm()!=Net.PlayerRealm.EARTH: return
	var weight := space_sky_weight_for_altitude(altitude)
	if not _ground_sky: _ground_sky=_environment.sky
	if weight<=0.0:
		if _space_sky_weight>0.0:
			_environment.sky=_ground_sky
			_environment.fog_enabled=_ground_fog_enabled
		_space_sky_weight=0.0
		return
	if _space_sky_weight<=0.0: _ground_fog_enabled=_environment.fog_enabled
	_space_sky_weight=weight
	if not _photographic_space:
		_photographic_space=LunarSky.new()
		_photographic_space.material.set_shader_parameter("earth_visibility",0.0)
		_space_sky=Sky.new()
		_space_sky.sky_material=_photographic_space.material
		_space_sky.radiance_size=Sky.RADIANCE_SIZE_32
		_space_sky.process_mode=Sky.PROCESS_MODE_INCREMENTAL
	_photographic_space.set_sun_direction(_sun.global_basis.z if _sun else Vector3(-0.29,0.78,-0.55))
	_photographic_space.material.set_shader_parameter("atmosphere_strength",1.0-weight)
	if _sky_material:
		for pair in [["atmosphere_top","sky_top_color"],["atmosphere_horizon","sky_horizon_color"],
				["atmosphere_bottom","ground_bottom_color"],["atmosphere_energy","sky_energy"]]:
			var value: Variant=_sky_material.get_shader_parameter(pair[1])
			if value!=null: _photographic_space.material.set_shader_parameter(pair[0],value)
	_environment.sky=_space_sky
	_environment.fog_enabled=_ground_fog_enabled and weight<1.0
