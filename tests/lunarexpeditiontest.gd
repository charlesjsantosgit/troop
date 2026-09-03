extends Node
## Deterministic lunar gameplay verification loaded after project autoloads:
##   godot --headless --path . res://scenes/main.tscn -- lunarexpeditiontest

var passed := 0
var total := 0


class DummyAdminActor:
	extends Node3D
	var display_name := "Test Astronaut"
	var last_teleport := Vector3.INF

	func admin_teleport(destination: Vector3) -> void:
		last_teleport = destination
		global_position = destination


func run() -> void:
	call_deferred("_run")


func _check(ok: bool, label: String, info := "") -> void:
	total += 1
	if ok:
		passed += 1
		print("  [ok] " + label)
	else:
		print("  [FAIL] " + label + ((" :: " + info) if info != "" else ""))


func _run() -> void:
	print("LUNAR EXPEDITION TEST")
	var stage := Node3D.new()
	stage.name = "LunarTestStage"
	add_child(stage)

	# --- backpack-gated deterministic inventory ----------------------------
	var inventory := LunarInventory.new()
	_check(not inventory.has_backpack() and inventory.slot_count() == 0,
		"monkeys have no inventory slots without a backpack")
	_check(inventory.add_item(LunarInventory.ITEM_BANANA, 5) == 5 \
			and inventory.count_item(LunarInventory.ITEM_BANANA) == 0,
		"items cannot be stored before a backpack is equipped")
	_check(inventory.equip_backpack(LunarInventory.Backpack.NORMAL) \
			and inventory.slot_count() == LunarInventory.NORMAL_SLOTS,
		"normal backpacks provide exactly twelve compact slots")
	_check(inventory.add_item(LunarInventory.ITEM_BANANA, 70) == 0 \
			and inventory.count_item(LunarInventory.ITEM_BANANA) == 70,
		"inventory fills deterministic existing and new stacks")
	var packed := inventory.slots_snapshot()
	_check(int(packed[0].count) == 64 and int(packed[1].count) == 6,
		"stack layout is stable and capped at sixty-four")
	_check(not inventory.equip_backpack(LunarInventory.Backpack.NONE),
		"a loaded backpack cannot be removed and destroy items")
	_check(inventory.move_slot(1, 3) and int(inventory.slots_snapshot()[3].count) == 6,
		"inventory slots support familiar grid rearrangement")

	var inventory_ui := BackpackInventoryUI.new()
	stage.add_child(inventory_ui)
	await get_tree().process_frame
	inventory_ui.bind_inventory(inventory)
	_check(inventory_ui.open_inventory() \
			and inventory_ui.displayed_slot_count() == LunarInventory.NORMAL_SLOTS,
		"compact inventory UI renders one button per available slot")
	inventory_ui.close_inventory()

	# --- life support and suit visuals -------------------------------------
	var suited_actor := DummyAdminActor.new()
	suited_actor.name = "SuitedMonkey"
	stage.add_child(suited_actor)
	var view_arms := FirstPersonArms.new()
	view_arms.configure(suited_actor)
	suited_actor.add_child(view_arms)
	await get_tree().process_frame
	var bare_sleeve_material: Material = view_arms._left_fore.material_override
	var bare_glove_material: Material = view_arms._glove_meshes[0].material_override
	var bandage_material: Material = view_arms._bandage_strip.material_override
	var suit := SpaceSuitSystem.new()
	_check(suit.equip_for(suited_actor, inventory),
		"space suit attaches to an arbitrary monkey integration node")
	await get_tree().process_frame
	_check(suit.equipped and suit.visual_primitive_count() >= 9 \
			and inventory.backpack_kind == LunarInventory.Backpack.SPACE \
			and inventory.slot_count() == LunarInventory.SPACE_SLOTS,
		"suit supplies visible helmet/tanks and an eighteen-slot space pack")
	var pressure_viewmodel_ok := view_arms.has_space_suit_presentation() \
		and view_arms._bandage_strip.material_override == bandage_material
	for sleeve in view_arms._sleeve_meshes:
		pressure_viewmodel_ok = pressure_viewmodel_ok \
			and sleeve.material_override \
				== SpaceSuitSystem.pressure_sleeve_material() \
			and sleeve.layers == 1
	for glove in view_arms._glove_meshes:
		pressure_viewmodel_ok = pressure_viewmodel_ok \
			and glove.material_override \
				== SpaceSuitSystem.pressure_glove_material() \
			and glove.layers == 1
	_check(pressure_viewmodel_ok,
		"first-person arms use matching pressure sleeves and gloves without recolouring bandages")
	suit.oxygen_seconds = 10.0
	suit.set_vacuum_exposure(true)
	suit.advance_life_support(4.0)
	_check(is_equal_approx(suit.oxygen_seconds, 6.0),
		"vacuum consumes oxygen at one real second per second")
	suit.refill_oxygen(5.0)
	_check(is_equal_approx(suit.oxygen_seconds, 11.0),
		"ship-compatible oxygen refill hook adds a precise bounded amount")
	suit.refill_oxygen()
	_check(is_equal_approx(suit.oxygen_seconds,
			SpaceSuitSystem.OXYGEN_CAPACITY_SECONDS),
		"full refill restores the twelve-minute tank capacity")
	suit.set_vacuum_exposure(false)
	var unequipped_ok := suit.unequip() \
		and not view_arms.has_space_suit_presentation()
	for sleeve in view_arms._sleeve_meshes:
		unequipped_ok = unequipped_ok \
			and sleeve.material_override == bare_sleeve_material
	for glove in view_arms._glove_meshes:
		unequipped_ok = unequipped_ok \
			and glove.material_override == bare_glove_material
	_check(unequipped_ok,
		"unequipping restores the exact first-person fur and paw materials")
	_check(suit.equip_for(suited_actor, inventory) \
			and view_arms.has_space_suit_presentation(),
		"re-equipping restores the first-person pressure garment")

	# Joint-parented shells are intentionally outside the suit node. Exercise a
	# complete actor exit/re-entry to ensure those roots rebuild once, stay on the
	# local-body render layer, and preserve life-support state.
	var suited_rig := MonkeyRig.new()
	suited_rig.setup(suited_actor.display_name, false)
	suited_actor.add_child(suited_rig)
	suit.oxygen_seconds = 321.0
	var suit_instance_id := suit.get_instance_id()
	stage.remove_child(suited_actor)
	var exit_cleared_visuals := suit.equipped \
		and suit.visual_primitive_count() == 0
	stage.add_child(suited_actor)
	await get_tree().process_frame
	var helmet_root := suited_rig.head_p.get_node_or_null("SpaceSuitHelmet")
	var helmet_mesh := helmet_root.get_node_or_null("ClearPressureHelmet") \
		if helmet_root else null
	var helmet_root_count := 0
	for child in suited_rig.head_p.get_children():
		if child.name == "SpaceSuitHelmet":
			helmet_root_count += 1
	_check(exit_cleared_visuals and suit.get_instance_id() == suit_instance_id \
			and suit.equipped and is_equal_approx(suit.oxygen_seconds, 321.0) \
			and suit.visual_primitive_count() == 20 \
			and helmet_root_count == 1 and helmet_root.visible \
			and helmet_mesh is MeshInstance3D \
			and helmet_mesh.layers == MonkeyRig.LOCAL_BODY_VISUAL_LAYER,
		"equipped articulated suit rebuilds once after actor tree re-entry")

	# --- playable moon, physical gravity, and admin route ------------------
	var moon := MoonWorld.new()
	moon.moon_seed = 741_969
	stage.add_child(moon)
	await get_tree().process_frame
	_check(is_equal_approx(MoonWorld.LUNAR_GRAVITY, 1.62) \
			and moon.gravity_at(moon.to_global(moon.surface_position(Vector3.UP))).is_equal_approx(
				Vector3(0.0, -1.62, 0.0)) \
			and is_equal_approx(moon.gravity_area.gravity, 1.62),
		"moon uses physical 1.62 m/s² gravity in both body and character hooks")
	_check(moon.terrain_vertex_count() == 24578 \
			and moon.terrain_triangle_count() == 49152 \
			and moon.terrain_mesh.mesh.get_surface_count() == 1,
		"closed spherical Moon stays within one bounded indexed terrain surface")
	var sampled_height := moon.height_at(123.0, -87.0)
	var peer_moon := MoonWorld.new()
	peer_moon.moon_seed = moon.moon_seed
	_check(is_equal_approx(sampled_height, peer_moon.height_at(123.0, -87.0)) \
			and not is_equal_approx(sampled_height,
				moon.height_at(-213.0, 166.0)),
		"lunar craters are peer-deterministic and spatially varied")
	_check(moon.cheese_shop != null and moon.cheese_shop.villager != null \
			and moon.cheese_shop.interaction_area != null \
			and moon.cheese_shop.get_node_or_null("PhysicalKiosk") \
				is StaticBody3D,
		"moon includes a physical interactive cheese kiosk and animated villager")
	var denied_position := suited_actor.global_position
	_check(not moon.admin_teleport_actor(suited_actor, false) \
			and suited_actor.global_position == denied_position,
		"moon teleport rejects non-admin callers")
	_check(moon.admin_teleport_actor(suited_actor, true) \
			and suited_actor.last_teleport.is_finite() \
			and suit.exposed_to_vacuum,
		"authorized admin teleport lands the suited monkey in lunar vacuum")
	var fresh_admin := DummyAdminActor.new()
	fresh_admin.name = "FreshAdminMonkey"
	stage.add_child(fresh_admin)
	_check(moon.admin_teleport_actor(fresh_admin, true) \
			and fresh_admin.get_node_or_null("SpaceSuitSystem") \
				is SpaceSuitSystem \
			and (fresh_admin.get_node("SpaceSuitSystem") as SpaceSuitSystem) \
				.exposed_to_vacuum,
		"admin moon teleport automatically issues a safe suit and oxygen tank")

	# --- cheese economy ----------------------------------------------------
	var trade_inventory := LunarInventory.new()
	trade_inventory.equip_backpack(LunarInventory.Backpack.NORMAL)
	var trade := moon.cheese_shop.purchase_with_balance(trade_inventory, 10, 2)
	_check(bool(trade.ok) and int(trade.balance) == 4 \
			and int(trade.cost) == 6 \
			and trade_inventory.count_item(LunarInventory.ITEM_MOON_CHEESE) == 2,
		"villager trades two moon cheeses for six authoritative bananas")
	trade_inventory.add_item(LunarInventory.ITEM_BANANA, 6)
	var backpack_trade := moon.cheese_shop.purchase_from_inventory(
		trade_inventory, 1)
	_check(bool(backpack_trade.ok) \
			and trade_inventory.count_item(LunarInventory.ITEM_BANANA) == 3 \
			and trade_inventory.count_item(LunarInventory.ITEM_MOON_CHEESE) == 3,
		"shop can atomically spend physical backpack bananas")
	var no_pack := LunarInventory.new()
	var rejected_trade := moon.cheese_shop.purchase_with_balance(no_pack, 99, 1)
	_check(not bool(rejected_trade.ok) and int(rejected_trade.balance) == 99,
		"shop preserves currency when the monkey has no backpack")

	# --- four-seat one-minute outbound rocket -------------------------------
	var rocket := LunarRocket.new()
	stage.add_child(rocket)
	await get_tree().process_frame
	rocket.set_physics_process(false)
	var earth_pose := Transform3D(Basis.IDENTITY,
		Vector3(0.0, LunarRocket.ORIGIN_ABOVE_LANDING_SURFACE + 0.6, 0.0))
	var moon_pose := moon.global_transform * moon.landing_transform()
	rocket.configure_route(earth_pose, moon_pose, earth_pose)
	_check(rocket.seat_nodes.size() == LunarRocket.MAX_CREW \
			and rocket.model_primitive_count() >= 15 \
			and rocket.get_node_or_null("LowerPressureHull") is CollisionShape3D \
			and rocket.get_node_or_null("UpperPressureHull") is CollisionShape3D,
		"rocket is a physical code-native hull with four modeled crew seats")
	var hull_bounds := rocket.hull_bounds()
	var cabin_floor := rocket.find_child("CabinFloorContact", true, false)
	_check(is_equal_approx(hull_bounds.end.y, 17.0) \
			and is_equal_approx(hull_bounds.position.y, -10.6) \
			and rocket.cabin_windows.size() == 12 \
			and cabin_floor is CollisionShape3D \
			and not rocket.has_node("ReturnOceanSurface"),
		"the 30 metre pressure hull has a solid cabin floor and twelve viewable glass windows")
	_check(rocket.flame_particle_budget() == 160,
		"launch and reentry fire use a bounded 160-particle budget")
	_check(rocket.lunar_dust_particle_budget() == 56 \
			and rocket.lunar_dust.fixed_fps >= 30 \
			and rocket.lunar_dust.fixed_fps <= 60 \
			and not rocket.lunar_dust.local_coords \
			and rocket.lunar_dust.top_level,
		"touchdown dust uses one bounded world-space 30-60 FPS particle field")
	var dust_mesh := rocket.lunar_dust_sheet.mesh as ArrayMesh
	var dust_vertices: PackedVector3Array = dust_mesh.surface_get_arrays(0)[
		Mesh.ARRAY_VERTEX]
	var dust_indices: PackedInt32Array = dust_mesh.surface_get_arrays(0)[
		Mesh.ARRAY_INDEX]
	_check(dust_vertices.size() <= 400 and dust_indices.size() / 3 <= 800,
		"spherical dust uses one bounded cached disk")
	var min_dust_altitude := INF
	var max_dust_altitude := -INF
	# The dust helper now serves both planets. Select its real lunar approach
	# phase before testing spherical ground; the parked Earth state is flat.
	rocket.state = LunarRocket.State.LUNAR_APPROACH
	for strength in [0.03, 0.15, 0.5, 1.0]:
		rocket._update_lunar_dust_sheet(strength)
		for vertex in dust_vertices:
			var altitude := moon.altitude_at(
				rocket.lunar_dust_sheet.global_transform * vertex)
			min_dust_altitude = minf(min_dust_altitude, altitude)
			max_dust_altitude = maxf(max_dust_altitude, altitude)
	# The Moon's coarser collision triangles sit slightly inside the analytic
	# sphere; the translucent dust layer must remain under 30 cm above them.
	_check(min_dust_altitude >= 0.10 and max_dust_altitude <= 0.30,
		"dust expansion hugs the actual curved landing terrain at every strength",
		"clearance=%.4f..%.4f m" % [min_dust_altitude, max_dust_altitude])
	var tilted_landing := moon_pose
	tilted_landing.basis = Basis(Vector3(0.7, 0.2, 0.5).normalized(), 1.4) \
		* moon_pose.basis
	rocket.moon_landing_transform = tilted_landing
	var max_dust_radial_error := 0.0
	var tangent_origin := tilted_landing.origin - tilted_landing.basis.y \
		* LunarRocket.ORIGIN_ABOVE_LANDING_SURFACE
	for strength in [0.15, 0.5, 1.0]:
		rocket._update_lunar_dust_sheet(strength)
		for vertex in dust_vertices:
			var local := tilted_landing.basis.inverse() * (
				rocket.lunar_dust_sheet.global_transform * vertex - tangent_origin)
			var surface_y := sqrt(MoonWorld.PLAYABLE_RADIUS_METERS ** 2 \
				- local.x * local.x - local.z * local.z) \
				- MoonWorld.PLAYABLE_RADIUS_METERS
			max_dust_radial_error = maxf(max_dust_radial_error,
				absf(local.y - surface_y - LunarRocket.DUST_SHEET_SURFACE_CLEARANCE))
	_check(max_dust_radial_error < 0.01,
		"dust curvature follows the landing frame's radial up when tilted",
		"max_error=%.5f m" % max_dust_radial_error)
	var dust_fade_preserved := is_equal_approx(
		rocket.lunar_dust_sheet.transparency, 0.14)
	rocket.moon_landing_transform = moon_pose
	rocket._update_lunar_dust_sheet(0.0)
	rocket.state = LunarRocket.State.EARTH_BOARDING
	_check(dust_fade_preserved and not rocket.lunar_dust_sheet.visible \
			and rocket.lunar_dust_sheet.mesh == dust_mesh,
		"dust preserves its fade and reuses geometry throughout expansion")
	var outbound_ascent_end := float(LunarRocket.OUTBOUND_PHASE_TIMES[0])
	var outbound_cruise_start := float(LunarRocket.OUTBOUND_PHASE_TIMES[1])
	var outbound_descent_start := float(LunarRocket.OUTBOUND_PHASE_TIMES[2])
	_check(LunarRocket.state_for_elapsed(true, outbound_ascent_end - 0.001) \
			== LunarRocket.State.LAUNCH_ASCENT \
			and LunarRocket.state_for_elapsed(true, outbound_ascent_end) \
				== LunarRocket.State.ATMOSPHERE_EXIT \
			and LunarRocket.state_for_elapsed(false, 28.0) \
				== LunarRocket.State.REENTRY,
		"network clocks map to exact shared cinematic state boundaries")
	var backdrop := rocket.voyage_visuals.backdrop_counts()
	_check(int(backdrop.stars) == SpaceVoyageVisuals.STAR_COUNT \
			and int(backdrop.planets) == 4 and int(backdrop.nebulae) == 3 \
			and int(backdrop.constellation_segments) == 15,
		"voyage backdrop includes stars, planets, nebulae, sun, and constellations")
	var galaxy_material := rocket.voyage_visuals.galaxy_visual.material_override \
		as StandardMaterial3D
	_check(int(backdrop.galaxies) == 1 \
			and galaxy_material != null and galaxy_material.albedo_texture \
				== SpaceVoyageVisuals.shared_galaxy_texture(),
		"voyage uses one bounded shared spiral-galaxy billboard")
	var earth_globe_mesh := rocket.voyage_visuals.earth_visual.mesh as SphereMesh
	var earth_globe_material: Material = \
		rocket.voyage_visuals.earth_visual.material_override
	var earth_globe_texture: Texture2D = null
	if earth_globe_material is StandardMaterial3D:
		earth_globe_texture = (earth_globe_material as StandardMaterial3D) \
			.albedo_texture
	elif earth_globe_material is ShaderMaterial:
		earth_globe_texture = (earth_globe_material as ShaderMaterial) \
			.get_shader_parameter("planet_atlas") as Texture2D
	_check(earth_globe_mesh != null \
			and earth_globe_mesh.radial_segments \
				== SpaceVoyageVisuals.CELESTIAL_RADIAL_SEGMENTS \
			and earth_globe_mesh.rings == SpaceVoyageVisuals.CELESTIAL_RINGS \
			and earth_globe_texture == SpaceVoyageVisuals.EARTH_ATLAS,
		"departure presents the complete map-textured Earth globe, not a flat proxy")
	var voyage_constants: Dictionary = rocket.voyage_visuals.get_script() \
		.get_script_constant_map()
	var authored_earth_diameter_km := float(voyage_constants.get(
		"EARTH_AUTHORED_DIAMETER_KM", -1.0))
	var authored_earth_radius_km := float(voyage_constants.get(
		"EARTH_AUTHORED_RADIUS_KM", -1.0))
	_check(is_equal_approx(authored_earth_diameter_km, 24_000.0) \
			and is_equal_approx(authored_earth_radius_km, 12_000.0) \
			and is_equal_approx(authored_earth_radius_km * 2.0,
				authored_earth_diameter_km),
		"scaled-space Earth is authored at the requested exact 24,000 km diameter",
		"diameter_km=%.1f radius_km=%.1f" % [
			authored_earth_diameter_km, authored_earth_radius_km])

	# The Earth under the launch pad is one persistent opaque object. Atmospheric
	# density and scaled-space geometry may change continuously, but alpha or a
	# second globe must never perform the surface-to-orbit handoff.
	var earth_instance_id := rocket.voyage_visuals.earth_visual.get_instance_id()
	var earth_globe_continuous := true
	var atmosphere_continuous := true
	var atmosphere_has_fractional_sample := false
	var atmosphere_has_thinned := false
	var max_atmosphere_step := 0.0
	var previous_atmosphere_density := 1.0
	var max_earth_geometry_step := 0.0
	var earth_geometry_changed := false
	var previous_earth_position := Vector3.ZERO
	var previous_earth_scale := 0.0
	var max_proxy_scale_ratio_step := 0.0
	var sky_shell_depth_clear := true
	var sky_shell_depth_samples := 0
	var maximum_earth_near_surface_depth := 0.0
	var sky_shell_mesh := rocket.voyage_visuals.space_shell.mesh as SphereMesh
	for frame in range(int(SpaceVoyageVisuals.LUNAR_MAP_REVEAL_SECONDS * 60.0) + 1):
		var elapsed := float(frame) / 60.0
		rocket.voyage_visuals.update_voyage(
			elapsed / LunarRocket.OUTBOUND_DURATION_SECONDS,
			LunarRocket.state_for_elapsed(true, elapsed), true)
		var earth_opacity := 1.0 \
			- float(rocket.voyage_visuals.earth_visual.transparency)
		earth_globe_continuous = earth_globe_continuous \
			and rocket.voyage_visuals.earth_visual.get_instance_id() \
				== earth_instance_id \
			and rocket.voyage_visuals.earth_visual.visible \
			and absf(earth_opacity - 1.0) < 0.0001
		var atmosphere_value: Variant = rocket.voyage_visuals.get(
			"atmosphere_density")
		var atmosphere_density := float(atmosphere_value) \
			if atmosphere_value != null else -1.0
		if frame > 0:
			var atmosphere_step := absf(
				atmosphere_density - previous_atmosphere_density)
			max_atmosphere_step = maxf(max_atmosphere_step, atmosphere_step)
			atmosphere_continuous = atmosphere_continuous \
				and atmosphere_density <= previous_atmosphere_density + 0.0001 \
				and atmosphere_step < 0.01
			var position_step := rocket.voyage_visuals.earth_visual.position \
				.distance_to(previous_earth_position) / maxf(maxf(
					rocket.voyage_visuals.earth_visual.position.length(),
					previous_earth_position.length()), 1.0)
			var scale_ratio_step := absf(
				rocket.voyage_visuals.earth_visual.scale.x - previous_earth_scale) \
				/ maxf(maxf(absf(rocket.voyage_visuals.earth_visual.scale.x),
					absf(previous_earth_scale)), 1.0)
			max_earth_geometry_step = maxf(max_earth_geometry_step,
				maxf(position_step, scale_ratio_step))
			max_proxy_scale_ratio_step = maxf(max_proxy_scale_ratio_step,
				scale_ratio_step)
			earth_geometry_changed = earth_geometry_changed \
				or position_step > 0.0001 or scale_ratio_step > 0.0001
		atmosphere_has_fractional_sample = atmosphere_has_fractional_sample \
			or (atmosphere_density > 0.05 and atmosphere_density < 0.95)
		atmosphere_has_thinned = atmosphere_has_thinned \
			or atmosphere_density <= 0.001
		var shell_opacity := 1.0 \
			- float(rocket.voyage_visuals.space_shell.transparency)
		if rocket.voyage_visuals.space_shell.visible and shell_opacity > 0.01:
			sky_shell_depth_samples += 1
			# The globe can be physically larger than the bounded vacuum shell
			# during the tangent-scale opening. What matters is ray depth: its near
			# surface must remain in front of the inward-facing shell.
			var near_surface_depth := maxf(
				rocket.voyage_visuals.earth_visual.position.length() \
					- rocket.voyage_visuals.earth_visual.scale.x, 0.0)
			maximum_earth_near_surface_depth = maxf(
				maximum_earth_near_surface_depth, near_surface_depth)
			sky_shell_depth_clear = sky_shell_depth_clear \
				and sky_shell_mesh != null \
				and near_surface_depth < sky_shell_mesh.radius * 0.98
		previous_atmosphere_density = atmosphere_density
		previous_earth_position = rocket.voyage_visuals.earth_visual.position
		previous_earth_scale = rocket.voyage_visuals.earth_visual.scale.x
	_check(earth_globe_continuous and earth_geometry_changed \
			and max_earth_geometry_step < 0.08 \
			and max_proxy_scale_ratio_step < 0.08,
		"one opaque Earth globe remains continuous from pad through orbital map view",
		"max_geometry_step=%.5f max_scale_ratio_step=%.5f" % [
			max_earth_geometry_step, max_proxy_scale_ratio_step])
	_check(atmosphere_continuous and atmosphere_has_fractional_sample \
			and atmosphere_has_thinned \
			and previous_atmosphere_density <= 0.001,
		"atmospheric visibility thins continuously to vacuum without a scene fade",
		"final_density=%.5f max_60fps_step=%.5f" % [
			previous_atmosphere_density, max_atmosphere_step])
	_check(sky_shell_depth_clear and sky_shell_depth_samples > 0,
		"materially visible vacuum backdrop remains behind Earth's near surface",
		"samples=%d max_near_depth=%.3f shell_radius=%.3f" % [
			sky_shell_depth_samples, maximum_earth_near_surface_depth,
			sky_shell_mesh.radius if sky_shell_mesh else -1.0])

	var crew_actors: Array[Node3D] = []
	for peer_id in range(1, 6):
		var actor := Node3D.new()
		actor.name = "CrewMonkey%d" % peer_id
		stage.add_child(actor)
		crew_actors.append(actor)
		var seat := rocket.board_crew(peer_id, actor)
		if peer_id <= 4:
			_check(seat == peer_id - 1, "crew member %d receives a stable seat" % peer_id)
		else:
			_check(seat == -1, "a fifth monkey cannot overfill the four-seat rocket")
	_check(rocket.crew_count() == 4 \
			and rocket.seat_global_transform(0).origin \
				!= rocket.seat_global_transform(1).origin,
		"all four occupied seat transforms remain distinct")

	var presentation_events := {"phase": 0, "camera": 0}
	rocket.presentation_phase_changed.connect(
		func(_phase: int, _is_outbound: bool) -> void:
			presentation_events.phase = int(presentation_events.phase) + 1)
	rocket.camera_cue.connect(
		func(_cue: StringName, _duration: float) -> void:
			presentation_events.camera = int(presentation_events.camera) + 1)
	_check(rocket.launch_to_moon() and rocket.state == LunarRocket.State.LAUNCH_ASCENT \
			and rocket.freeze and rocket.collision_layer == 0 \
			and rocket.launch_plume.emitting and rocket.voyage_visuals.visible \
			and not rocket.voyage_visuals.star_field.visible,
		"launch ignition starts flame/presentation while atmosphere hides stars")
	var earth_scale_at_launch := rocket.voyage_visuals.earth_scale()
	var ascent_a := rocket._flight_transform(0.03)
	var ascent_b := rocket._flight_transform(0.12)
	_check(Vector2(ascent_a.origin.x, ascent_a.origin.z).distance_to(
			Vector2(earth_pose.origin.x, earth_pose.origin.z)) < 0.001 \
			and Vector2(ascent_b.origin.x, ascent_b.origin.z).distance_to(
				Vector2(earth_pose.origin.x, earth_pose.origin.z)) < 0.001 \
			and ascent_b.origin.y > ascent_a.origin.y \
			and ascent_b.basis.y.dot(Vector3.UP) > 0.98,
		"initial rocket path rises straight up with its nose on the tangent")
	var earth_launch_up := earth_pose.basis.y.normalized()
	var early_ascent_heights: Array[float] = []
	var early_ascent_steps: Array[float] = []
	var early_ascent_pinned := true
	for elapsed in [0.0, 1.0, 2.0, 3.0, 4.0]:
		var early_pose := rocket._flight_transform(
			float(elapsed) / LunarRocket.OUTBOUND_DURATION_SECONDS)
		var launch_delta := early_pose.origin - earth_pose.origin
		var launch_height := launch_delta.dot(earth_launch_up)
		early_ascent_pinned = early_ascent_pinned \
			and (launch_delta - earth_launch_up * launch_height).length() < 0.001
		if not early_ascent_heights.is_empty():
			early_ascent_steps.append(launch_height - early_ascent_heights[-1])
		early_ascent_heights.append(launch_height)
	var slow_start_accelerates := early_ascent_steps.size() == 4 \
		and early_ascent_steps[0] > 0.0 \
		and early_ascent_steps[0] < early_ascent_steps[1] \
		and early_ascent_steps[1] < early_ascent_steps[2] \
		and early_ascent_steps[2] < early_ascent_steps[3]
	_check(early_ascent_pinned and slow_start_accelerates,
		"Earth liftoff starts slowly and accelerates upward without lateral drift",
		"one_second_rises=%s" % [early_ascent_steps])
	var landing_up := moon_pose.basis.y.normalized()
	var approach_clearances: Array[float] = []
	var approach_above_pad := true
	var approach_descends := true
	var approach_upright := true
	var approach_duration := LunarRocket.OUTBOUND_DURATION_SECONDS \
		- outbound_descent_start
	for elapsed in [outbound_descent_start, outbound_descent_start + 2.0,
			outbound_descent_start + 4.0, outbound_descent_start + 6.0,
			outbound_descent_start + 8.0, outbound_descent_start + 9.0,
			outbound_descent_start + 9.5]:
		var approach_pose := rocket._flight_transform(
			float(elapsed) / LunarRocket.OUTBOUND_DURATION_SECONDS)
		var clearance := (approach_pose.origin - moon_pose.origin).dot(landing_up)
		if not approach_clearances.is_empty():
			approach_descends = approach_descends \
				and clearance < approach_clearances[-1]
		approach_clearances.append(clearance)
		approach_above_pad = approach_above_pad and clearance > 0.0
		approach_upright = approach_upright \
			and approach_pose.basis.y.normalized().dot(landing_up) > 0.999
	_check(is_equal_approx(approach_duration, 10.0) \
			and approach_above_pad and approach_descends and approach_upright,
		"final ten seconds stay above the lunar pad and descend monotonically upright",
		"clearances=%s" % [approach_clearances])
	rocket.advance_voyage(outbound_ascent_end - 0.001)
	_check(rocket.state == LunarRocket.State.LAUNCH_ASCENT,
		"outbound ascent owns the complete authored launch window")
	rocket.advance_voyage(0.001)
	_check(rocket.state == LunarRocket.State.ATMOSPHERE_EXIT \
			and rocket.voyage_visuals.star_field.visible,
		"atmosphere exit begins at the canonical boundary with stars revealed")
	rocket.advance_voyage(outbound_cruise_start - outbound_ascent_end)
	_check(rocket.state == LunarRocket.State.SPACE_CRUISE \
			and rocket.atmosphere_fraction() == 0.0 \
			and rocket.voyage_visuals.earth_scale() < earth_scale_at_launch,
		"space phase reveals stars while the whole Earth visibly recedes")
	rocket.advance_voyage(outbound_descent_start - outbound_cruise_start)
	_check(rocket.state == LunarRocket.State.LUNAR_APPROACH,
		"camera pan and lunar approach begin with ten seconds remaining")
	_check(not rocket.lunar_dust.emitting,
		"lunar dust remains off while the upright lander is high above the surface")
	rocket.advance_voyage(approach_duration - 1.0)
	_check(rocket.state != LunarRocket.State.LANDED_MOON \
			and absf(rocket.remaining_seconds() - 1.0) < 0.0002 \
			and rocket.lunar_dust.emitting \
			and rocket.lunar_dust.amount_ratio > 0.90 \
			and rocket.lunar_dust.global_position.distance_to(
				moon_pose.origin - landing_up \
					* (LunarRocket.ORIGIN_ABOVE_LANDING_SURFACE - 0.12)) < 0.01,
		"touchdown burn produces dense dust at the real lunar contact point before cutoff")
	rocket.advance_voyage(0.999)
	_check(rocket.state == LunarRocket.State.LUNAR_APPROACH \
			and absf(rocket.remaining_seconds() - 0.001) < 0.0002 \
			and not rocket.lunar_dust.emitting \
			and not rocket.launch_plume.emitting \
			and not rocket.exhaust_flame_core.visible \
			and rocket.landing_gear_deployment > 0.999 \
			and rocket.landing_strut_compression > 0.999,
		"final contact compresses deployed struts and finishes engine/dust cutoff before the exact minute")
	rocket.advance_voyage(0.001)
	_check(rocket.state == LunarRocket.State.LANDED_MOON \
			and is_equal_approx(rocket.voyage_elapsed,
				LunarRocket.OUTBOUND_DURATION_SECONDS) \
			and rocket.global_transform.is_equal_approx(moon_pose) \
			and not rocket.voyage_visuals.visible,
		"outbound voyage lands at exactly 60.000 seconds")
	var all_suited := true
	for peer_id in range(1, 5):
		var equipment: Dictionary = rocket.crew_equipment(peer_id)
		var crew_suit: SpaceSuitSystem = equipment.get("suit")
		var crew_inventory: LunarInventory = equipment.get("inventory")
		all_suited = all_suited and is_instance_valid(crew_suit) \
			and crew_suit.exposed_to_vacuum \
			and crew_inventory.backpack_kind == LunarInventory.Backpack.SPACE
	_check(all_suited,
		"touchdown equips every monkey with a live tank and space backpack")
	_check(int(presentation_events.phase) == 4 \
			and int(presentation_events.camera) == 5,
		"outbound emits every presentation phase plus launch/touchdown camera cues",
		"phases=%d camera=%d" % [int(presentation_events.phase),
			int(presentation_events.camera)])
	_check(rocket.refill_crew_oxygen() == 4,
		"rocket oxygen station refills all four registered suits")

	# --- faster fiery return and powered landing on the original pad --------
	_check(rocket.begin_return_to_earth() \
			and LunarRocket.RETURN_DURATION_SECONDS \
				< LunarRocket.OUTBOUND_DURATION_SECONDS,
		"return begins from the moon and remains faster than outbound")
	var ascent_heights: Array[float] = []
	var ascent_climbs := true
	var ascent_pinned := true
	var ascent_upright := true
	for elapsed in [0.0, 1.0, 2.0, 3.0, 4.0, 5.0, 5.9]:
		var return_pose := rocket._flight_transform(
			float(elapsed) / LunarRocket.RETURN_DURATION_SECONDS)
		var moon_delta := return_pose.origin - moon_pose.origin
		var ascent_height := moon_delta.dot(landing_up)
		var lateral_offset := moon_delta - landing_up * ascent_height
		if not ascent_heights.is_empty():
			ascent_climbs = ascent_climbs and ascent_height > ascent_heights[-1]
		ascent_heights.append(ascent_height)
		ascent_pinned = ascent_pinned and lateral_offset.length() < 0.001
		ascent_upright = ascent_upright \
			and return_pose.basis.y.normalized().dot(landing_up) > 0.999
	_check(ascent_climbs and ascent_pinned and ascent_upright,
		"Moon return ascent climbs monotonically with pinned XZ and an upright hull",
		"heights=%s" % [ascent_heights])
	rocket.advance_voyage(28.0)
	_check(rocket.state == LunarRocket.State.REENTRY \
			and not rocket.reentry_flames.emitting \
			and is_zero_approx(rocket.reentry_flames.amount_ratio),
		"physical heat-shield reentry starts its continuous plasma ramp at exactly 28 seconds")
	rocket.advance_voyage(1.0)
	_check(rocket.reentry_flames.emitting \
			and rocket.reentry_flames.amount_ratio > 0.1 \
			and rocket.reentry_flames.amount_ratio < 0.9,
		"reentry plasma grows through a visible intermediate intensity instead of popping on")
	rocket.advance_voyage(11.0)
	_check(rocket.state == LunarRocket.State.OCEAN_APPROACH,
		"final five seconds transition from reentry to an upright powered pad landing")
	var earth_landings_descend := true
	var last_earth_height := INF
	for elapsed in [40.0, 41.0, 42.0, 43.0, 44.0, 44.9]:
		var arrival := rocket._flight_transform(float(elapsed) / LunarRocket.RETURN_DURATION_SECONDS)
		var offset := arrival.origin - earth_pose.origin
		earth_landings_descend = earth_landings_descend and offset.y > 0.0 \
			and offset.y < last_earth_height \
			and Vector2(offset.x, offset.z).length() < 0.001 \
			and arrival.basis.y.dot(Vector3.UP) > 0.999
		last_earth_height = offset.y
	_check(earth_landings_descend,
		"the final Earth approach descends vertically with an upright hull over the actual launchpad")
	rocket.advance_voyage(4.999)
	_check(rocket.state != LunarRocket.State.SPLASHDOWN,
		"return does not complete a millisecond early")
	rocket.advance_voyage(0.001)
	_check(rocket.state == LunarRocket.State.SPLASHDOWN \
			and rocket.global_transform.is_equal_approx(earth_pose) \
			and rocket.freeze and not rocket.reentry_flames.emitting,
		"45-second return ends planted upright on the original Earth launchpad")
	var terminal_pose := rocket.global_transform
	var all_shutdown_planted := true
	for age in [0.0, 0.5, 1.5, 3.0]:
		rocket.present_landing_recovery(age)
		all_shutdown_planted = all_shutdown_planted \
			and rocket.global_transform.is_equal_approx(terminal_pose) \
			and rocket.landing_gear_deployment > 0.999 \
			and rocket.landing_strut_compression > 0.999 \
			and not rocket.launch_plume.emitting \
			and not rocket.reentry_flames.emitting
	_check(all_shutdown_planted and is_equal_approx(Net.ROCKET_RECOVERY_SECONDS, 3.0),
		"three-second engine shutdown preserves planted legs and the same landing position without automatic travel")
	_check(rocket.network_state_snapshot().crew.size() == 4,
		"network snapshot carries the authoritative voyage clock and four crew ids")
	_check(rocket.disembark_crew(4) and not rocket.can_board(),
		"terminal landing allows deliberate crew exit while the three-second shutdown keeps new boarding locked")
	var replica := LunarRocket.new()
	stage.add_child(replica)
	await get_tree().process_frame
	replica.set_physics_process(false)
	replica.configure_route(earth_pose, moon_pose, earth_pose)
	replica.apply_authoritative_clock(LunarRocket.State.LANDED_MOON, true,
		LunarRocket.OUTBOUND_DURATION_SECONDS)
	_check(replica.global_transform.is_equal_approx(moon_pose) \
			and is_equal_approx(replica.gravity_scale,
				MoonWorld.LUNAR_GRAVITY / 9.81),
		"late-joining replica snaps to the authoritative lunar endpoint and gravity")
	replica.apply_authoritative_clock(LunarRocket.State.SPLASHDOWN, false,
		LunarRocket.RETURN_DURATION_SECONDS)
	_check(replica.global_transform.is_equal_approx(earth_pose) and replica.freeze,
		"late-joining replica reconstructs the planted capsule at the original Earth launchpad")

	peer_moon.free()
	stage.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame
	print("LUNAREXPEDITIONTEST %d/%d %s" % [passed, total,
		"PASS" if passed == total else "FAIL"])
	get_tree().quit(0 if passed == total else 1)
