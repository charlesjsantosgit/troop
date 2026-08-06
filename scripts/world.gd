class_name World
extends Node3D
## Owns the streamed infinite jungle plus lighting, ambience, players/puppets.

const HorizonChunkScript = preload("res://scripts/horizon_chunk.gd")

signal combat_score_changed
signal headshot_scored(source: Node3D, target: Node3D, lethal: bool, distance: float)

const BUILD_BUDGET := 1  # cap streaming work to avoid traversal frame spikes
const HORIZON_BUILD_BUDGET := 1
const HORIZON_TREE_SOURCE_BUDGET := 4
const NEAR_PREDICTION_TIME := 0.65
const DEFEAT_VIEW_TIME := 2.35
const MELEE_RADIUS := 0.88
const MELEE_DAMAGE := [24.0, 29.0, 38.0]
const LIGHTING_UPDATE_STEP := 0.05
const SKY_UPDATE_STEP := 0.50
const CLOCK_RESYNC_STEP := 1.0
const CALENDAR_CHECK_STEP := 60.0
const MOON_SKY_ENERGY := 3.8

static var _muzzle_mesh: SphereMesh
static var _muzzle_material: StandardMaterial3D
static var _impact_mesh: SphereMesh
static var _impact_world_material: StandardMaterial3D
static var _impact_actor_material: StandardMaterial3D

var chunks: Dictionary = {}          # Vector2i -> Chunk
var _queue: Array = []
var _near_pending: Dictionary = {}
var _collision_queue: Array[Chunk] = []
var _chunk_detail_queue: Array[Chunk] = []
var horizon_chunks: Dictionary = {}  # Vector2i -> HorizonChunk macro sectors
var _horizon_queue: Array = []
var _horizon_pending: Dictionary = {}
var _horizon_detail_queue: Array[HorizonChunk] = []
var _stream_center := Vector2i(0x3fffffff, 0x3fffffff)
var _prefetch_center := Vector2i(0x3fffffff, 0x3fffffff)
var _horizon_center := Vector2i(0x3fffffff, 0x3fffffff)
var local_player: MonkeyPlayer
var puppets: Dictionary = {}         # peer id -> Puppet
var _marker: MeshInstance3D
var _particles: GPUParticles3D
var water_fx: WaterFX
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
var combat_kills: Dictionary = {}
var practice_targets: Array[PracticeTarget] = []
var _t := 0.0
var _biome_sample_timer := 0.0
var _biome_fog_target := Color(0.43, 0.61, 0.43)
var _biome_density_target := 0.0017
var _biome_saturation_target := 1.08


func build() -> void:
	RenderingServer.directional_shadow_atlas_set_size(2048, true)
	_prepare_combat_fx()
	BananaBullet.prepare_resources()
	_apply_season(SeasonalCycle.season_from_system())
	time_of_day_hours = Net.authoritative_cycle_hour()
	water_fx = WaterFX.new()
	water_fx.name = "WaterFX"
	water_fx.setup(Gen.WATER_Y)
	add_child(water_fx)
	var env := Environment.new()
	_environment = env
	_celestial_sky = CelestialSky.new()
	var sky_mat := _celestial_sky.get_material()
	_sky_material = sky_mat
	var sky := Sky.new()
	sky.sky_material = sky_mat
	sky.process_mode = Sky.PROCESS_MODE_INCREMENTAL
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.58
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_exposure = 0.92
	env.glow_enabled = true
	env.glow_intensity = 0.38
	env.glow_strength = 0.62
	env.glow_bloom = 0.06
	env.ssao_enabled = true
	env.ssao_radius = 2.2
	env.ssao_intensity = 1.7
	env.ssao_power = 1.3
	# SSAO supplies the important canopy depth. SSIL and volumetrics cost much
	# more on an integrated GPU, so the performance tier leaves them optional.
	env.ssil_enabled = false
	env.ssil_radius = 3.5
	env.ssil_intensity = 0.65
	env.fog_enabled = true
	env.fog_light_color = Color(0.43, 0.61, 0.43)
	env.fog_density = 0.0017
	env.fog_height = 2.0
	env.fog_height_density = 0.055
	env.fog_sky_affect = 0.12
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
	env.adjustment_saturation = 1.08
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	var sun := DirectionalLight3D.new()
	_sun = sun
	sun.rotation_degrees = Vector3(-40, -34, 0)
	sun.light_color = Color(1.0, 0.91, 0.70)
	sun.light_energy = 1.18
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

	# A joining client receives this authoritative snapshot before World exists.
	# Copying it before chunks stream makes already-claimed huts register open.
	opened_supply_huts = Net.claimed_supply_chests.duplicate()
	Net.banana_taken.connect(_on_banana_taken)
	Net.supply_chest_claimed.connect(_on_supply_chest_claimed)
	Net.vine_released.connect(_on_vine_released)
	Net.bullet_fired.connect(_on_network_bullet)
	Net.melee_swung.connect(_on_network_melee)
	Net.peer_defeated.connect(_on_peer_defeated)


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
func nearby_supply_chest(player: Node3D) -> SupplyHut:
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


## Claim and animate the nearest chest. Solo play preserves the immediate path;
## multiplayer waits for the host's winning claim before mutating inventory.
func try_open_supply_chest(player: Node3D) -> bool:
	var hut := nearby_supply_chest(player)
	if not hut:
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
	if player.has_method("receive_supply_loot"):
		player.call("receive_supply_loot", hut.ammo_kind, hut.ammo_amount,
			hut.bandage_count)
	return true


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
	if local_player and is_instance_valid(local_player) \
			and local_player.has_method("receive_supply_loot"):
		local_player.call("receive_supply_loot", int(payload.get("ammo_kind", 0)),
			int(payload.get("ammo_amount", 0)), int(payload.get("bandages", 0)))


func spawn_local(peer_id: int, pname: String) -> MonkeyPlayer:
	var p := MonkeyPlayer.new()
	p.peer_id = peer_id
	p.display_name = pname
	p.is_local = true
	p.world = self
	var jitter := Vector3(float(peer_id % 5) - 2.0, 0, float((peer_id / 5) % 5) - 2.0)
	p.position = spawn_point() + jitter
	add_child(p)
	local_player = p
	combat_kills[peer_id] = 0
	_ensure_seasonal_weather()
	_apply_scarf_state()
	return p


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


func respawn(p: MonkeyPlayer) -> void:
	if p.state == p.S.SWING:
		p._release(false)
	var pos := p.global_position
	p.global_position = Vector3(pos.x, Gen.height(pos.x, pos.z) + 3.0, pos.z)
	p.reset_physics_interpolation()
	p.velocity = Vector3.ZERO


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
	best_target.take_damage(MELEE_DAMAGE[combo_index], shooter, impulse)
	Sfx.play_at("melee_hit",
		best_target.global_position + Vector3.UP * 0.75, -3.0)
	return best_target


func _on_network_bullet(shooter_id: int, origin: Vector3,
		initial_velocity: Vector3, damage: float, headshot_rule: bool,
		play_fx: bool, weapon_kind: int) -> void:
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
	var x := -4.0 if actor == local_player else 12.0
	var z := 4.0 if actor == local_player else -14.0
	actor.revive_at(Vector3(x, Gen.height(x, z) + 2.2, z))


func height_at(x: float, z: float) -> float:
	return Gen.height(x, z)


func water_surface_y(x: float, z: float) -> float:
	return Visuals.water_surface_y(x, z, _t)


# ---- streaming -------------------------------------------------------------

func center_chunk() -> Vector2i:
	var c := local_player.global_position if local_player else Vector3.ZERO
	return Vector2i(floori(c.x / Gen.CHUNK), floori(c.z / Gen.CHUNK))


func _process(dt: float) -> void:
	_t += dt
	_update_day_night(dt)
	_stream(BUILD_BUDGET)
	if local_player:
		Visuals.set_far_focus(local_player.global_position)
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
				_biome_density_target = 0.00145
				_biome_saturation_target = 1.06
			Gen.Biome.WETLAND:
				_biome_fog_target = Color(0.34, 0.58, 0.53)
				_biome_density_target = 0.00205
				_biome_saturation_target = 0.99
			Gen.Biome.HIGHLAND:
				_biome_fog_target = Color(0.56, 0.67, 0.62)
				_biome_density_target = 0.00235
				_biome_saturation_target = 0.96
			_:
				_biome_fog_target = Color(0.43, 0.61, 0.43)
				_biome_density_target = 0.0017
				_biome_saturation_target = 1.08
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
		_biome_density_target * density_multiplier,
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
		0.025 + (1.0 - weather_light) * 0.12, 0.12, daylight_amount)
	var sunrise_color := Color(1.0, 0.42, 0.16)
	var noon_color := Color(1.0, 0.955, 0.86)
	_sun.light_color = sunrise_color.lerp(noon_color, high_sun)
	_sun.light_energy = daylight_amount * lerpf(0.42, 1.24, high_sun) \
		* weather_light
	_sun.shadow_enabled = daylight_amount > 0.08
	_moon.light_energy = (1.0 - daylight_amount) * 0.27 * weather_light
	# Cloudy seasonal weather attenuates the visible disc more strongly than the
	# diffuse moonlight, so rain and snow do not leave a pasted-on white circle.
	_moon_visual_strength = (1.0 - daylight_amount) * MOON_SKY_ENERGY \
		* weather_light * weather_light
	_environment.ambient_light_energy = lerpf(0.23, 0.60,
		daylight_amount) * lerpf(0.90, weather_light, 0.58)
	_environment.tonemap_exposure = lerpf(0.87, 0.96, daylight_amount)
	_environment.adjustment_brightness = lerpf(0.91, 0.98, daylight_amount)
	if _particles:
		_particles.emitting = season == SeasonalCycle.Season.SUMMER \
			and daylight_amount < 0.52

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
	var ground_bottom := Color(0.008, 0.025, 0.075).lerp(
		Color(0.08, 0.18, 0.11), daylight_amount)
	var ground_horizon := Color(0.025, 0.080, 0.165).lerp(
		Color(0.30, 0.48, 0.34), daylight_amount)
	var sky_energy := lerpf(0.68, 0.92, daylight_amount) \
		* lerpf(1.0, weather_light, 0.48)
	_celestial_sky.update_palette(sky_top, sky_horizon,
		ground_bottom, ground_horizon, sky_energy)
	_celestial_sky.update_celestials(daylight_amount, weather_light,
		moon_source_direction(), _moon_visual_strength, time_of_day_hours,
		_sun.global_basis.z.normalized())


func _stream(budget: int) -> void:
	var cc := center_chunk()
	var predicted := _predicted_near_center(cc)
	if cc != _stream_center or predicted != _prefetch_center:
		_refresh_near_targets(cc, predicted)
	var hc := center_horizon_sector()
	if hc != _horizon_center:
		_refresh_horizon_targets(hc)
	var did_heavy_work := false
	if not _queue.is_empty():
		var n := mini(budget, _queue.size())
		for i in range(n):
			var k: Vector2i = _queue.pop_front()
			_near_pending.erase(k)
			if (_chunk_in_window(k, cc, Gen.VIEW_R) \
					or _chunk_in_window(k, predicted, Gen.VIEW_R)) \
					and not chunks.has(k):
				_build_chunk(k, true)
				did_heavy_work = true
	# Only the current and adjacent chunks need collision broadphase entries.
	# A full 48 m safety ring remains around even the fastest monkey.
	for k in chunks:
		var collision_delta: Vector2i = (k - cc).abs()
		var wants_collision := maxi(collision_delta.x, collision_delta.y) <= 1
		var chunk: Chunk = chunks[k]
		if wants_collision and not chunk.has_collisions() \
				and not chunk.is_deferred_build_pending():
			if not _collision_queue.has(chunk):
				_collision_queue.append(chunk)
		else:
			if not wants_collision:
				_collision_queue.erase(chunk)
			chunk.set_collision_active(wants_collision)

	# Spend at most one heavy streaming token per frame. Gameplay collision wins
	# over decorative completion and horizon work once the terrain shell is safe.
	if not did_heavy_work and not _collision_queue.is_empty():
		_collision_queue.sort_custom(func(a: Chunk, b: Chunk):
			return Vector2(a.key - cc).length_squared() < Vector2(b.key - cc).length_squared())
		var collision_chunk: Chunk = _collision_queue.pop_front()
		if is_instance_valid(collision_chunk):
			collision_chunk.set_collision_active(true)
			did_heavy_work = true

	# Publish coarse horizon shells before decorative near-chunk stages. This keeps
	# the backdrop independent and bounded while center-chunk collision already
	# protects the newly joined player.
	if not did_heavy_work and not _horizon_queue.is_empty():
		var n := mini(HORIZON_BUILD_BUDGET, _horizon_queue.size())
		for i in range(n):
			var k: Vector2i = _horizon_queue.pop_front()
			_horizon_pending.erase(k)
			var delta := (k - hc).abs()
			if maxi(delta.x, delta.y) <= Gen.HORIZON_VIEW_R \
					and not horizon_chunks.has(k):
				_build_horizon_chunk(k, true)
				did_heavy_work = true

	if not did_heavy_work:
		while not _chunk_detail_queue.is_empty():
			var detail_chunk: Chunk = _chunk_detail_queue.pop_front()
			if not is_instance_valid(detail_chunk) \
					or not detail_chunk.is_deferred_build_pending():
				continue
			var finished := detail_chunk.finish_deferred_build_step()
			if finished:
				_register_chunk_bananas(detail_chunk)
			else:
				_chunk_detail_queue.append(detail_chunk)
			did_heavy_work = true
			break

	# Tree silhouettes and other visual detail use only otherwise-idle frames.
	if not did_heavy_work:
		while not _horizon_detail_queue.is_empty():
			var detail_sector: HorizonChunk = _horizon_detail_queue.front()
			if not is_instance_valid(detail_sector) \
					or detail_sector.is_queued_for_deletion():
				_horizon_detail_queue.pop_front()
				continue
			if detail_sector.build_tree_step(HORIZON_TREE_SOURCE_BUDGET):
				_horizon_detail_queue.pop_front()
			did_heavy_work = true
			break


func center_horizon_sector() -> Vector2i:
	var c := local_player.global_position if local_player else Vector3.ZERO
	var sector_size := Gen.CHUNK * Gen.HORIZON_SECTOR_CHUNKS
	return Vector2i(floori(c.x / sector_size), floori(c.z / sector_size))


func _predicted_near_center(cc: Vector2i) -> Vector2i:
	if not local_player:
		return cc
	var lead := local_player.global_position \
		+ local_player.velocity * NEAR_PREDICTION_TIME
	var raw := Vector2i(floori(lead.x / Gen.CHUNK),
		floori(lead.z / Gen.CHUNK))
	var offset := raw - cc
	return cc + Vector2i(clampi(offset.x, -1, 1), clampi(offset.y, -1, 1))


func _chunk_in_window(k: Vector2i, center: Vector2i, radius: int) -> bool:
	var delta := (k - center).abs()
	return maxi(delta.x, delta.y) <= radius


func _append_near_window(target_center: Vector2i) -> void:
	for dx in range(-Gen.VIEW_R, Gen.VIEW_R + 1):
		for dz in range(-Gen.VIEW_R, Gen.VIEW_R + 1):
			var k := target_center + Vector2i(dx, dz)
			if not chunks.has(k) and not _near_pending.has(k):
				_queue.append(k)
				_near_pending[k] = true


func _refresh_near_targets(cc: Vector2i, predicted: Vector2i) -> void:
	_stream_center = cc
	_prefetch_center = predicted
	_queue.clear()
	_near_pending.clear()
	_append_near_window(cc)
	if predicted != cc:
		_append_near_window(predicted)
	_queue.sort_custom(func(a, b):
		var actual_a := _chunk_in_window(a, cc, Gen.VIEW_R)
		var actual_b := _chunk_in_window(b, cc, Gen.VIEW_R)
		if actual_a != actual_b:
			return actual_a
		var lead_a := Vector2(a - predicted).length_squared()
		var lead_b := Vector2(b - predicted).length_squared()
		if is_equal_approx(lead_a, lead_b):
			return Vector2(a - cc).length_squared() \
				< Vector2(b - cc).length_squared()
		return lead_a < lead_b)

	var dead: Array = []
	for k in chunks:
		if not _chunk_in_window(k, cc, Gen.DROP_R) \
				and not _chunk_in_window(k, predicted, Gen.VIEW_R):
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


func _refresh_horizon_targets(hc: Vector2i) -> void:
	_horizon_center = hc
	_horizon_queue.clear()
	_horizon_pending.clear()
	for dx in range(-Gen.HORIZON_VIEW_R, Gen.HORIZON_VIEW_R + 1):
		for dz in range(-Gen.HORIZON_VIEW_R, Gen.HORIZON_VIEW_R + 1):
			var k := hc + Vector2i(dx, dz)
			if not horizon_chunks.has(k):
				_horizon_queue.append(k)
				_horizon_pending[k] = true
	_horizon_queue.sort_custom(func(a, b):
		return Vector2(a - hc).length_squared() \
			< Vector2(b - hc).length_squared())
	var dead: Array = []
	for k in horizon_chunks:
		var d: Vector2i = (k - hc).abs()
		if maxi(d.x, d.y) > Gen.HORIZON_DROP_R:
			dead.append(k)
	for k in dead:
		var sector: HorizonChunk = horizon_chunks[k]
		_horizon_detail_queue.erase(sector)
		sector.queue_free()
		horizon_chunks.erase(k)


func _build_chunk(k: Vector2i, defer_outer_details := true) -> void:
	var c := Chunk.new()
	add_child(c)
	var d := (k - center_chunk()).abs()
	var needs_collision := maxi(d.x, d.y) <= 1
	# Runtime streaming publishes terrain shells first even in the safety ring.
	# Detail and collision construction then use bounded per-frame stages; the
	# player cannot traverse the 48 m center chunk before that ring is completed.
	var defer_details := defer_outer_details
	c.setup(k, Net.collected, needs_collision, defer_details)
	chunks[k] = c
	if defer_details:
		_chunk_detail_queue.append(c)
	else:
		_register_chunk_bananas(c)


func _register_chunk_bananas(chunk: Chunk) -> void:
	if not is_instance_valid(chunk):
		return
	for child in chunk.get_children():
		if child is Banana:
			register_banana(child)


func _build_horizon_chunk(k: Vector2i, defer_trees := true) -> void:
	var sector = HorizonChunkScript.new()
	add_child(sector)
	sector.setup(k, defer_trees)
	horizon_chunks[k] = sector
	if defer_trees:
		_horizon_detail_queue.append(sector)


func warm(radius: int) -> void:
	var cc := center_chunk()
	for dx in range(-radius, radius + 1):
		for dz in range(-radius, radius + 1):
			var k := cc + Vector2i(dx, dz)
			if not chunks.has(k):
				_build_chunk(k, false)
	# Nine coarse sectors provide an immediate 288 m+ backdrop. The remaining
	# sectors stream over subsequent frames without blocking world entry.
	var hc := center_horizon_sector()
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			var hk := hc + Vector2i(dx, dz)
			if not horizon_chunks.has(hk):
				_build_horizon_chunk(hk, false)


## Fast online entry: publish one fully playable chunk and let the normal
## one-token streaming budget fill the surrounding jungle after the player is
## visible. Solo/test warm() keeps its deterministic full-radius semantics.
func warm_online_entry() -> void:
	var cc := center_chunk()
	if not chunks.has(cc):
		_build_chunk(cc, false)


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
