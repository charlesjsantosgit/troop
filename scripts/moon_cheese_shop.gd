class_name MoonCheeseShop
extends Node3D
## A pressurized lunar kiosk and its independent, articulated cheesekeeper. The
## economy supports both TROOP's authoritative banana score (balance in/out)
## and physical backpack bananas, while inventory insertion remains atomic.

signal trade_completed(quantity: int, bananas_paid: int, new_balance: int)
signal trade_rejected(reason: String)

const CHEESE_PRICE_BANANAS := 3
const CHEESE_STACK_SIZE := 16
const MerchantScript := preload("res://scripts/moon_merchant.gd")

static var _shop_material: StandardMaterial3D
static var _window_material: StandardMaterial3D
static var _cheese_material: StandardMaterial3D
static var _light_material: StandardMaterial3D
static var _foundation_material: StandardMaterial3D

var interaction_area: Area3D
var villager: MoonMerchant


func _ready() -> void:
	name = "MoonCheeseShop"
	if get_child_count() == 0:
		_build_shop()
	set_process(false)


func update_customer(customer: Node3D) -> void:
	if is_instance_valid(villager):
		villager.set_customer(customer)


## The merchant and counter are both usable from the open forecourt, with a
## height check so someone on the roof or behind the solid shell cannot trade.
func is_customer_in_range(customer: Node3D, maximum_range := 7.0) -> bool:
	if not is_instance_valid(customer) or not is_instance_valid(villager):
		return false
	var local_customer := to_local(customer.global_position)
	if local_customer.z > -1.7 or absf(local_customer.y) > 3.0:
		return false
	# A patrolling merchant can stand several metres from the kiosk. Keep the
	# entire client prompt inside the server's fixed shop envelope, otherwise a
	# buyer beside him could open a panel that rejects every remote order.
	var authority_range := float(Net.MOON_CHEESE_SHOP_RANGE) - 0.2
	if customer.global_position.distance_squared_to(global_position) \
			> authority_range * authority_range:
		return false
	var range_sq := maximum_range * maximum_range
	return customer.global_position.distance_squared_to(villager.global_position) \
		<= range_sq or customer.global_position.distance_squared_to(
			to_global(Vector3(0.0, 0.0, -3.2))) <= range_sq


func begin_trade(customer: Node3D) -> void:
	if is_instance_valid(villager):
		villager.begin_trade(customer)


func end_trade() -> void:
	if is_instance_valid(villager):
		villager.end_trade()


func react_to_trade(accepted: bool, quantity: int, reason := "") -> void:
	if is_instance_valid(villager):
		villager.react_to_trade(accepted, quantity, reason)


func quote(quantity := 1) -> int:
	return CHEESE_PRICE_BANANAS * maxi(quantity, 0)


func purchase_with_balance(customer_inventory: LunarInventory,
		banana_balance: int, quantity := 1) -> Dictionary:
	quantity = maxi(quantity, 1)
	var cost := quote(quantity)
	if not customer_inventory or not customer_inventory.has_backpack():
		return _reject("A normal or space backpack is required.", banana_balance)
	if banana_balance < cost:
		return _reject("Not enough bananas.", banana_balance)
	if not customer_inventory.can_add(LunarInventory.ITEM_MOON_CHEESE,
			quantity, CHEESE_STACK_SIZE):
		return _reject("The backpack has no room for moon cheese.",
			banana_balance)
	var remainder := customer_inventory.add_item(
		LunarInventory.ITEM_MOON_CHEESE, quantity, CHEESE_STACK_SIZE)
	if remainder != 0:
		return _reject("The cheese stack changed during trade.", banana_balance)
	var new_balance := banana_balance - cost
	react_to_trade(true, quantity)
	trade_completed.emit(quantity, cost, new_balance)
	return {"ok": true, "balance": new_balance, "quantity": quantity,
		"cost": cost, "reason": ""}


func purchase_from_inventory(customer_inventory: LunarInventory,
		quantity := 1) -> Dictionary:
	quantity = maxi(quantity, 1)
	var cost := quote(quantity)
	if not customer_inventory or not customer_inventory.has_backpack():
		return _reject("A normal or space backpack is required.", 0)
	var balance := customer_inventory.count_item(LunarInventory.ITEM_BANANA)
	if balance < cost:
		return _reject("Not enough backpack bananas.", balance)
	if not customer_inventory.can_add(LunarInventory.ITEM_MOON_CHEESE,
			quantity, CHEESE_STACK_SIZE):
		return _reject("The backpack has no room for moon cheese.", balance)
	customer_inventory.remove_item(LunarInventory.ITEM_BANANA, cost)
	var remainder := customer_inventory.add_item(
		LunarInventory.ITEM_MOON_CHEESE, quantity, CHEESE_STACK_SIZE)
	if remainder != 0:
		# This branch should be unreachable after can_add, but rollback preserves
		# currency if another integration mutates slots from a signal callback.
		customer_inventory.add_item(LunarInventory.ITEM_BANANA, cost)
		return _reject("The cheese stack changed during trade.", balance)
	var new_balance := balance - cost
	react_to_trade(true, quantity)
	trade_completed.emit(quantity, cost, new_balance)
	return {"ok": true, "balance": new_balance, "quantity": quantity,
		"cost": cost, "reason": ""}


func _reject(reason: String, balance: int) -> Dictionary:
	react_to_trade(false, 0, reason)
	trade_rejected.emit(reason)
	return {"ok": false, "balance": balance, "quantity": 0,
		"cost": 0, "reason": reason}


func _build_shop() -> void:
	_ensure_materials()
	_add_box(self, "KioskShell", Vector3(7.2, 3.8, 4.8),
		Vector3(0.0, 1.9, 0.0), _shop_material)
	_add_box(self, "FrontWindow", Vector3(4.6, 1.65, 0.10),
		Vector3(0.0, 2.15, -2.45), _window_material)
	_add_box(self, "Counter", Vector3(5.3, 0.75, 0.85),
		Vector3(0.0, 1.0, -2.80), _shop_material)
	_add_box(self, "ServingAwning", Vector3(7.5, 0.18, 1.55),
		Vector3(0.0, 3.79, -2.55), _shop_material)
	_add_box(self, "AwningLightStrip", Vector3(5.5, 0.06, 0.12),
		Vector3(0.0, 3.67, -3.18), _light_material)
	for side in [-1.0, 1.0]:
		_add_box(self, "KioskCornerTrim", Vector3(0.16, 3.5, 0.10),
			Vector3(side * 3.35, 1.86, -2.45), _window_material)
	# A single local, non-shadowing fixture makes the resident readable when
	# the sun is behind the kiosk without adding a dynamic shadow pass.
	var counter_light := OmniLight3D.new()
	counter_light.name = "ForecourtWorkLight"
	counter_light.position = Vector3(0.0, 2.8, -4.1)
	counter_light.light_color = Color(1.0, 0.88, 0.65)
	counter_light.light_energy = 1.3
	counter_light.omni_range = 10.0
	counter_light.omni_attenuation = 0.85
	counter_light.shadow_enabled = false
	add_child(counter_light)
	var kiosk_body := StaticBody3D.new()
	kiosk_body.name = "PhysicalKiosk"
	kiosk_body.collision_layer = 1
	kiosk_body.collision_mask = 1
	var kiosk_collision := CollisionShape3D.new()
	var kiosk_shape := BoxShape3D.new()
	kiosk_shape.size = Vector3(7.2, 3.8, 4.8)
	kiosk_collision.shape = kiosk_shape
	kiosk_collision.position = Vector3(0.0, 1.9, 0.0)
	kiosk_body.add_child(kiosk_collision)
	var counter_collision := CollisionShape3D.new()
	var counter_shape := BoxShape3D.new()
	counter_shape.size = Vector3(5.3, 0.75, 0.85)
	counter_collision.shape = counter_shape
	counter_collision.position = Vector3(0.0, 1.0, -2.80)
	kiosk_body.add_child(counter_collision)
	var awning_collision := CollisionShape3D.new()
	var awning_shape := BoxShape3D.new()
	awning_shape.size = Vector3(7.5, 0.18, 1.55)
	awning_collision.shape = awning_shape
	awning_collision.position = Vector3(0.0, 3.79, -2.55)
	kiosk_body.add_child(awning_collision)
	add_child(kiosk_body)
	_build_foundation(kiosk_body)
	# Cheese-wheel roof beacon makes the shop recognizable from the lander.
	var cheese_wheel := CylinderMesh.new()
	cheese_wheel.top_radius = 0.72
	cheese_wheel.bottom_radius = 0.72
	cheese_wheel.height = 0.34
	cheese_wheel.radial_segments = 16
	var wheel := _add_mesh(self, "CheeseBeacon", cheese_wheel,
		Vector3(0.0, 4.18, 0.0), _cheese_material)
	wheel.rotation.x = PI * 0.5
	var sign := Label3D.new()
	sign.name = "CheeseShopSign"
	sign.text = "CRATER & CURD"
	sign.font_size = 48
	sign.modulate = Color(1.0, 0.88, 0.36)
	sign.outline_size = 8
	sign.position = Vector3(0.0, 3.38, -2.53)
	sign.rotation.y = PI
	sign.pixel_size = 0.008
	add_child(sign)
	var price_sign := Label3D.new()
	price_sign.name = "MoonCheesePrice"
	price_sign.text = "CHEESE · CROPS · CONTRACTS"
	price_sign.font_size = 30
	price_sign.pixel_size = 0.007
	price_sign.outline_size = 6
	price_sign.position = Vector3(0.0, 2.72, -2.53)
	price_sign.rotation.y = PI
	price_sign.modulate = Color(0.88, 0.94, 1.0)
	add_child(price_sign)

	interaction_area = Area3D.new()
	interaction_area.name = "TradeInteraction"
	interaction_area.collision_layer = 0
	interaction_area.collision_mask = 1
	var interaction_shape := CollisionShape3D.new()
	var interaction_box := BoxShape3D.new()
	interaction_box.size = Vector3(7.2, 3.0, 3.0)
	interaction_shape.shape = interaction_box
	interaction_shape.position = Vector3(0.0, 1.4, -3.5)
	interaction_area.add_child(interaction_shape)
	add_child(interaction_area)

	villager = MerchantScript.new()
	villager.configure(self)
	add_child(villager)


## A rigid storefront spans several curved terrain triangles. Its wall base
## alone can leave a bright gap under one corner; a real, colliding foundation
## extends below all perimeter samples without shifting the shop or terrain.
func _build_foundation(kiosk_body: StaticBody3D) -> void:
	var half_width := 3.67
	var half_depth := 2.47
	var bottom := -0.14
	var lunar_world := get_parent() as Node3D
	if lunar_world and lunar_world.has_method("surface_position_at"):
		for x in [-half_width, 0.0, half_width]:
			for z in [-half_depth, 0.0, half_depth]:
				var ground: Vector3 = lunar_world.call("surface_position_at",
					to_global(Vector3(x, 0.0, z)))
				bottom = minf(bottom, to_local(ground).y - 0.08)
	var top := 0.055
	var size := Vector3(half_width * 2.0, top - bottom, half_depth * 2.0)
	var center := Vector3(0.0, (top + bottom) * 0.5, 0.0)
	_add_box(self, "TerrainFoundation", size, center, _foundation_material)
	var shape := BoxShape3D.new()
	shape.size = size
	var collision := CollisionShape3D.new()
	collision.name = "FoundationCollision"
	collision.shape = shape
	collision.position = center
	kiosk_body.add_child(collision)


static func _add_box(parent: Node3D, part_name: String, size: Vector3,
		local_position: Vector3, material: Material) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = size
	return _add_mesh(parent, part_name, mesh, local_position, material)


static func _add_mesh(parent: Node3D, part_name: String, mesh: PrimitiveMesh,
		local_position: Vector3, material: Material) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	instance.name = part_name
	instance.mesh = mesh
	instance.position = local_position
	instance.material_override = material
	parent.add_child(instance)
	return instance


static func _ensure_materials() -> void:
	if _shop_material:
		return
	_shop_material = StandardMaterial3D.new()
	_shop_material.albedo_color = Color(0.76, 0.78, 0.81)
	_shop_material.metallic = 0.10
	_shop_material.roughness = 0.64
	_window_material = StandardMaterial3D.new()
	_window_material.albedo_color = Color(0.035, 0.075, 0.13)
	_window_material.metallic = 0.12
	_window_material.roughness = 0.38
	_cheese_material = StandardMaterial3D.new()
	_cheese_material.albedo_color = Color(1.0, 0.73, 0.12)
	_cheese_material.roughness = 0.72
	_cheese_material.emission_enabled = true
	_cheese_material.emission = Color(0.20, 0.09, 0.01)
	_light_material = StandardMaterial3D.new()
	_light_material.albedo_color = Color(1.0, 0.93, 0.73)
	_light_material.emission_enabled = true
	_light_material.emission = Color(1.0, 0.88, 0.6)
	_light_material.emission_energy_multiplier = 1.3
	_foundation_material = StandardMaterial3D.new()
	_foundation_material.albedo_color = Color(0.34, 0.38, 0.41)
	_foundation_material.roughness = 0.93
