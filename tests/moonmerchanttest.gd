extends Node
## Run after autoload initialization with -- moonmerchanttest.
## Checks the actual lunar merchant against the actual sphere collider.

var passed := 0
var total := 0


func run() -> void:
	call_deferred("_run")


func _check(ok: bool, label: String, info := "") -> void:
	total += 1
	if ok:
		passed += 1
		print("  [ok] " + label)
	else:
		print("  [FAIL] " + label + (" :: " + info if not info.is_empty() else ""))


func _frames(count: int) -> void:
	for _frame in range(count):
		await get_tree().physics_frame
	await get_tree().process_frame


func _boot_sole_altitude(moon: MoonWorld, boot: MeshInstance3D) -> float:
	var up := moon.radial_up_at(boot.global_position)
	var lowest := INF
	var sole := boot.global_position
	for vertex in boot.mesh.get_faces():
		var offset: Vector3 = boot.global_basis * vertex
		var height := offset.dot(up)
		if height < lowest:
			lowest = height
			sole = boot.global_position + offset
	return moon.altitude_at(sole)


func _run() -> void:
	print("MOON MERCHANT TEST")
	var moon := MoonWorld.new()
	add_child(moon)
	await get_tree().process_frame
	var shop := moon.cheese_shop
	var merchant := shop.villager
	_check(merchant is CharacterBody3D and merchant.rig is MonkeyRig \
			and merchant.rig.sh_l != null and merchant.rig.kn_r != null \
			and merchant.suit.equipped and merchant.suit.visual_primitive_count() == 20,
		"cheesekeeper has a real character body, jointed monkey rig and fitted lunar suit")
	_check(merchant.rig.head_p.get_node_or_null("CheeseHat") != null \
			and merchant.rig.torso_p.get_node_or_null("GoldenCheesemakerApron") != null \
			and merchant.suit.has_breathable_oxygen(),
		"merchant has distinct cheese livery and a working resident oxygen system")
	await _frames(135)
	_check(merchant.is_on_floor() \
			and absf(moon.altitude_at(merchant.global_position)) < 0.8 \
			and merchant.up_direction.dot(moon.radial_up_at(merchant.global_position)) > 0.999,
		"merchant settles on lunar collision and stands along radial gravity",
		"on_floor=%s altitude=%.4f" % [merchant.is_on_floor(),
			moon.altitude_at(merchant.global_position)])
	var soles: Array[float] = []
	for foot in [merchant.rig.foot_l, merchant.rig.foot_r]:
		for root in foot.get_children():
			for part in root.get_children():
				if part is MeshInstance3D and "LunarBoot" in String(part.name):
					soles.append(_boot_sole_altitude(moon, part))
	var soles_planted := soles.size() == 2
	for sole in soles:
		soles_planted = soles_planted and sole >= -0.04 and sole <= 0.06
	_check(soles_planted,
		"grounded merchant boot soles meet actual lunar terrain within the collision margin",
		"sole_altitudes=%s" % [soles])
	var foundation := shop.get_node("TerrainFoundation") as MeshInstance3D
	var foundation_collision := shop.get_node("PhysicalKiosk/FoundationCollision") as CollisionShape3D
	var foundation_box := foundation.mesh as BoxMesh
	var foundation_bottom := foundation.position.y - foundation_box.size.y * 0.5
	var foundation_closed := true
	for x in [-foundation_box.size.x * 0.5, 0.0, foundation_box.size.x * 0.5]:
		for z in [-foundation_box.size.z * 0.5, 0.0, foundation_box.size.z * 0.5]:
			foundation_closed = foundation_closed and moon.altitude_at(
				shop.to_global(Vector3(x, foundation_bottom, z))) <= 0.005
	_check(foundation_closed and foundation_collision.position.is_equal_approx(foundation.position) \
			and (foundation_collision.shape as BoxShape3D).size.is_equal_approx(foundation_box.size),
		"storefront has a grounded foundation with matching physical collision across its curved footprint")
	var start_position := merchant.global_position
	await _frames(230)
	_check(merchant.global_position.distance_to(start_position) > 0.5 \
			and merchant.global_position.distance_to(merchant.home) < 8.0,
		"unattended merchant walks a bounded physical patrol instead of bobbing in place",
		"travel=%.3f" % merchant.global_position.distance_to(start_position))
	var side := merchant.global_basis.x
	var centre := merchant.global_position + merchant.up_direction * 0.65
	var ray := PhysicsRayQueryParameters3D.create(centre + side * 1.2,
		centre - side * 1.2, 1)
	var hit := merchant.get_world_3d().direct_space_state.intersect_ray(ray)
	_check(not hit.is_empty() and hit.get("collider") == merchant,
		"merchant capsule blocks the same physical collision layer as players")
	var customer := Node3D.new()
	moon.add_child(customer)
	customer.global_position = moon.surface_position_at(shop.to_global(
		Vector3(-1.0, 0.0, -7.0)), 0.05)
	var events := {"greetings": 0, "cheese": 0}
	merchant.greeted.connect(func(_actor: Node3D) -> void:
		events.greetings = int(events.greetings) + 1)
	merchant.order_presented.connect(func(quantity: int) -> void:
		events.cheese = int(events.cheese) + quantity)
	shop.update_customer(customer)
	await _frames(25)
	_check(int(events.greetings) == 1 and merchant.activity == MoonMerchant.Activity.GREETING,
		"approaching customer receives one greeting and an articulated wave")
	var arm_pose := merchant.rig.el_l.rotation
	await _frames(12)
	_check(merchant.rig.el_l.rotation.distance_to(arm_pose) > 0.025,
		"greeting animates the merchant elbow instead of moving an entire fixture")
	_check(shop.is_customer_in_range(customer, 7.0),
		"forecourt customer can interact directly with the cheesekeeper")
	customer.global_position = shop.to_global(Vector3(0.0, 0.0, 3.0))
	_check(not shop.is_customer_in_range(customer, 7.0),
		"shop cannot be opened through its rear wall")
	customer.global_position = shop.to_global(Vector3(0.0, 5.0, -3.0))
	_check(not shop.is_customer_in_range(customer, 7.0),
		"shop cannot be opened through the roof")
	customer.global_position = moon.surface_position_at(merchant.global_position \
		- shop.global_basis.z * 8.0, 0.05)
	_check(not shop.is_customer_in_range(customer, 8.5),
		"merchant patrol cannot expose a trade prompt outside the server shop envelope")
	customer.global_position = moon.surface_position_at(shop.to_global(
		Vector3(-1.0, 0.0, -7.0)), 0.05)
	shop.begin_trade(customer)
	await _frames(35)
	var trading_position := merchant.global_position
	await _frames(60)
	var facing := -merchant.rig.yaw_node.global_basis.z
	var to_customer := (customer.global_position - merchant.global_position) \
		.slide(merchant.up_direction).normalized()
	_check(merchant.activity == MoonMerchant.Activity.TRADING \
			and merchant.global_position.distance_to(trading_position) < 0.15 \
			and facing.dot(to_customer) > 0.95,
		"merchant stops and faces the buyer for the duration of trade",
		"facing_dot=%.4f drift=%.4f" % [facing.dot(to_customer),
			merchant.global_position.distance_to(trading_position)])
	var inventory := LunarInventory.new()
	inventory.equip_backpack(LunarInventory.Backpack.SPACE)
	var result := shop.purchase_with_balance(inventory, 10, 2)
	await _frames(2)
	_check(bool(result.ok) and int(result.balance) == 4 \
			and inventory.count_item(LunarInventory.ITEM_MOON_CHEESE) == 2 \
			and int(events.cheese) == 2 \
			and merchant.activity == MoonMerchant.Activity.THANKING \
			and merchant.cheese_sample.visible,
		"paid order delivers exact cheese and triggers the merchant handoff gesture")
	result = shop.purchase_with_balance(inventory, 0, 1)
	_check(not bool(result.ok) and int(result.balance) == 0 \
			and inventory.count_item(LunarInventory.ITEM_MOON_CHEESE) == 2 \
			and merchant.status_label.text == "Not enough bananas.",
		"rejected order preserves inventory and gives a visible merchant response")
	merchant.take_damage(999.0, customer, side * 500.0)
	_check(is_instance_valid(merchant) and merchant.activity == MoonMerchant.Activity.FLINCH \
			and merchant.velocity.length() < 2.3,
		"stray fire causes a bounded physical flinch without deleting the merchant")
	shop.end_trade()
	shop.update_customer(null)
	await _frames(360)
	_check(merchant.is_on_floor() and merchant.global_position.distance_to(merchant.home) < 8.0,
		"merchant remains grounded and resumes work after trade and a physical impulse")
	for direction in [Vector3.LEFT, Vector3.DOWN, Vector3.FORWARD]:
		merchant.home = moon.to_global(moon.surface_position(direction))
		merchant.global_position = merchant.home + direction * 0.65
		merchant.velocity = Vector3.ZERO
		merchant.activity = MoonMerchant.Activity.IDLE
		merchant._activity_remaining = 30.0
		merchant.reset_physics_interpolation()
		await _frames(130)
		_check(merchant.is_on_floor() \
				and absf(moon.altitude_at(merchant.global_position)) < 0.8 \
				and merchant.up_direction.dot(direction) > 0.999,
			"merchant falls and collides correctly on spherical face %s" % direction,
			"on_floor=%s altitude=%.4f" % [merchant.is_on_floor(),
				moon.altitude_at(merchant.global_position)])
	moon.visible = false
	var hidden_position := merchant.global_position
	var hidden_clock := merchant._time
	await _frames(35)
	_check(merchant.global_position.is_equal_approx(hidden_position) \
			and is_equal_approx(merchant._time, hidden_clock),
		"hidden lunar scene does not advance merchant physics or AI")
	moon.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame
	print("MOONMERCHANTTEST %d/%d %s" % [passed, total,
		"PASS" if passed == total else "FAIL"])
	get_tree().quit(0 if passed == total else 1)
