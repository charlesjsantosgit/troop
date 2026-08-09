extends SceneTree
## Standalone deterministic lunar gameplay verification. Run with:
##   godot --headless --path . -s tests/lunarexpeditiontest.gd

var passed := 0
var total := 0


class DummyAdminActor:
	extends Node3D
	var last_teleport := Vector3.INF

	func admin_teleport(destination: Vector3) -> void:
		last_teleport = destination
		global_position = destination


func _initialize() -> void:
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
	root.add_child(stage)

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
	await process_frame
	inventory_ui.bind_inventory(inventory)
	_check(inventory_ui.open_inventory() \
			and inventory_ui.displayed_slot_count() == LunarInventory.NORMAL_SLOTS,
		"compact inventory UI renders one button per available slot")
	inventory_ui.close_inventory()

	# --- life support and suit visuals -------------------------------------
	var suited_actor := DummyAdminActor.new()
	suited_actor.name = "SuitedMonkey"
	stage.add_child(suited_actor)
	var suit := SpaceSuitSystem.new()
	_check(suit.equip_for(suited_actor, inventory),
		"space suit attaches to an arbitrary monkey integration node")
	await process_frame
	_check(suit.equipped and suit.visual_primitive_count() == 8 \
			and inventory.backpack_kind == LunarInventory.Backpack.SPACE \
			and inventory.slot_count() == LunarInventory.SPACE_SLOTS,
		"suit supplies visible helmet/tanks and an eighteen-slot space pack")
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

	# --- playable moon, physical gravity, and admin route ------------------
	var moon := MoonWorld.new()
	moon.moon_seed = 741_969
	stage.add_child(moon)
	await process_frame
	_check(is_equal_approx(MoonWorld.LUNAR_GRAVITY, 1.62) \
			and moon.gravity_at(Vector3.ZERO).is_equal_approx(
				Vector3(0.0, -1.62, 0.0)) \
			and is_equal_approx(moon.gravity_area.gravity, 1.62),
		"moon uses physical 1.62 m/s² gravity in both body and character hooks")
	_check(moon.terrain_vertex_count() == 4225 \
			and moon.terrain_triangle_count() == 8192 \
			and moon.terrain_mesh.mesh.get_surface_count() == 1,
		"cratered landing zone stays within one bounded indexed terrain surface")
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

	# --- four-seat 180-second outbound rocket ------------------------------
	var rocket := LunarRocket.new()
	stage.add_child(rocket)
	await process_frame
	rocket.set_physics_process(false)
	var earth_pose := Transform3D(Basis.IDENTITY, Vector3(0.0, 5.0, 0.0))
	var moon_pose := moon.global_transform * moon.landing_transform()
	var ocean_pose := Transform3D(Basis(Vector3.UP, 0.72),
		Vector3(840.0, 0.6, -620.0))
	rocket.configure_route(earth_pose, moon_pose, ocean_pose)
	_check(rocket.seat_nodes.size() == LunarRocket.MAX_CREW \
			and rocket.model_primitive_count() >= 15 \
			and rocket.get_node_or_null("PhysicalRocketHull") != null,
		"rocket is a physical code-native hull with four modeled crew seats")
	_check(rocket.flame_particle_budget() == 160,
		"launch and reentry fire use a bounded 160-particle budget")
	_check(LunarRocket.state_for_elapsed(true, 27.999) \
			== LunarRocket.State.LAUNCH_ASCENT \
			and LunarRocket.state_for_elapsed(true, 28.0) \
				== LunarRocket.State.ATMOSPHERE_EXIT \
			and LunarRocket.state_for_elapsed(false, 75.0) \
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
	rocket.advance_voyage(27.999)
	_check(rocket.state == LunarRocket.State.LAUNCH_ASCENT,
		"outbound ascent owns the first 28 seconds")
	rocket.advance_voyage(0.001)
	_check(rocket.state == LunarRocket.State.ATMOSPHERE_EXIT \
			and rocket.voyage_visuals.star_field.visible,
		"atmosphere exit begins at exactly 28 seconds with stars revealed")
	rocket.advance_voyage(34.0)
	_check(rocket.state == LunarRocket.State.SPACE_CRUISE \
			and rocket.atmosphere_fraction() == 0.0 \
			and rocket.voyage_visuals.earth_scale() < earth_scale_at_launch,
		"space phase reveals stars while the whole Earth visibly recedes")
	rocket.advance_voyage(92.0)
	_check(rocket.state == LunarRocket.State.LUNAR_APPROACH,
		"camera pan and lunar approach begin at 154 seconds")
	rocket.advance_voyage(25.999)
	_check(rocket.state != LunarRocket.State.LANDED_MOON \
			and absf(rocket.remaining_seconds() - 0.001) < 0.0002,
		"rocket remains in flight until the full three minutes elapse")
	rocket.advance_voyage(0.001)
	_check(rocket.state == LunarRocket.State.LANDED_MOON \
			and is_equal_approx(rocket.voyage_elapsed,
				LunarRocket.OUTBOUND_DURATION_SECONDS) \
			and rocket.global_transform.is_equal_approx(moon_pose) \
			and not rocket.voyage_visuals.visible,
		"outbound voyage lands at exactly 180.000 seconds")
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

	# --- faster fiery return and splashdown --------------------------------
	_check(rocket.begin_return_to_earth() \
			and LunarRocket.RETURN_DURATION_SECONDS \
				< LunarRocket.OUTBOUND_DURATION_SECONDS,
		"return begins from the moon and is one minute faster")
	rocket.advance_voyage(75.0)
	_check(rocket.state == LunarRocket.State.REENTRY \
			and rocket.reentry_flames.emitting,
		"physical heat-shield reentry starts fiery plasma at 75 seconds")
	rocket.advance_voyage(33.0)
	_check(rocket.state == LunarRocket.State.OCEAN_APPROACH,
		"final twelve seconds transition from flames to ocean approach")
	rocket.advance_voyage(11.999)
	_check(rocket.state != LunarRocket.State.SPLASHDOWN,
		"return does not complete a millisecond early")
	rocket.advance_voyage(0.001)
	_check(rocket.state == LunarRocket.State.SPLASHDOWN \
			and rocket.global_transform.is_equal_approx(ocean_pose) \
			and rocket.freeze and not rocket.reentry_flames.emitting,
		"120-second return ends frozen upright at the authored ocean splash point")
	_check(rocket.network_state_snapshot().crew.size() == 4,
		"network snapshot carries the authoritative voyage clock and four crew ids")
	_check(rocket.disembark_crew(4) and not rocket.can_board(),
		"splashdown presentation keeps boarding locked during crew recovery")
	var replica := LunarRocket.new()
	stage.add_child(replica)
	await process_frame
	replica.set_physics_process(false)
	replica.configure_route(earth_pose, moon_pose, ocean_pose)
	replica.apply_authoritative_clock(LunarRocket.State.LANDED_MOON, true,
		LunarRocket.OUTBOUND_DURATION_SECONDS)
	_check(replica.global_transform.is_equal_approx(moon_pose) \
			and is_equal_approx(replica.gravity_scale,
				MoonWorld.LUNAR_GRAVITY / 9.81),
		"late-joining replica snaps to the authoritative lunar endpoint and gravity")
	replica.apply_authoritative_clock(LunarRocket.State.SPLASHDOWN, false,
		LunarRocket.RETURN_DURATION_SECONDS)
	_check(replica.global_transform.is_equal_approx(ocean_pose) and replica.freeze,
		"late-joining replica snaps to the authoritative ocean splashdown")

	peer_moon.free()
	stage.queue_free()
	await process_frame
	await process_frame
	print("LUNAREXPEDITIONTEST %d/%d %s" % [passed, total,
		"PASS" if passed == total else "FAIL"])
	quit(0 if passed == total else 1)
