class_name MoonCheeseShop
extends Node3D
## A tiny pressurized-looking lunar kiosk and its cheese-hatted villager. The
## economy supports both TROOP's authoritative banana score (balance in/out)
## and physical backpack bananas, while inventory insertion remains atomic.

signal trade_completed(quantity: int, bananas_paid: int, new_balance: int)
signal trade_rejected(reason: String)

const CHEESE_PRICE_BANANAS := 3
const CHEESE_STACK_SIZE := 16

static var _shop_material: StandardMaterial3D
static var _window_material: StandardMaterial3D
static var _cheese_material: StandardMaterial3D
static var _villager_fur: StandardMaterial3D

var interaction_area: Area3D
var villager: Node3D
var _villager_base_y := 0.0
var _animation_time := 0.0


func _ready() -> void:
	name = "MoonCheeseShop"
	if get_child_count() == 0:
		_build_shop()
	set_process(true)


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
	trade_completed.emit(quantity, cost, new_balance)
	return {"ok": true, "balance": new_balance, "quantity": quantity,
		"cost": cost, "reason": ""}


func _reject(reason: String, balance: int) -> Dictionary:
	trade_rejected.emit(reason)
	return {"ok": false, "balance": balance, "quantity": 0,
		"cost": 0, "reason": reason}


func _process(delta: float) -> void:
	_animation_time = fmod(_animation_time + delta, TAU)
	if villager:
		villager.position.y = _villager_base_y \
			+ sin(_animation_time * 1.7) * 0.045
		villager.rotation.y = sin(_animation_time * 0.65) * 0.08


func _build_shop() -> void:
	_ensure_materials()
	_add_box(self, "KioskShell", Vector3(7.2, 3.8, 4.8),
		Vector3(0.0, 1.9, 0.0), _shop_material)
	_add_box(self, "FrontWindow", Vector3(4.6, 1.65, 0.10),
		Vector3(0.0, 2.15, -2.45), _window_material)
	_add_box(self, "Counter", Vector3(5.3, 0.75, 0.85),
		Vector3(0.0, 1.0, -2.80), _shop_material)
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
	add_child(kiosk_body)
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
	sign.text = "MOON CHEESE  ·  🍌 3"
	sign.font_size = 52
	sign.modulate = Color(1.0, 0.88, 0.36)
	sign.outline_size = 8
	sign.position = Vector3(0.0, 3.38, -2.53)
	sign.pixel_size = 0.008
	add_child(sign)

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

	villager = Node3D.new()
	villager.name = "MuensterTheMoonMerchant"
	villager.position = Vector3(0.0, 1.48, -2.48)
	_villager_base_y = villager.position.y
	add_child(villager)
	_build_villager(villager)


func _build_villager(root: Node3D) -> void:
	var body_mesh := SphereMesh.new()
	body_mesh.radius = 0.48
	body_mesh.height = 0.96
	body_mesh.radial_segments = 14
	body_mesh.rings = 8
	_add_mesh(root, "VillagerBody", body_mesh, Vector3.ZERO,
		_villager_fur)
	var muzzle_mesh := SphereMesh.new()
	muzzle_mesh.radius = 0.30
	muzzle_mesh.height = 0.42
	muzzle_mesh.radial_segments = 12
	muzzle_mesh.rings = 6
	_add_mesh(root, "Muzzle", muzzle_mesh, Vector3(0.0, -0.02, -0.39),
		_cheese_material)
	for side in [-1.0, 1.0]:
		var eye_mesh := SphereMesh.new()
		eye_mesh.radius = 0.065
		eye_mesh.height = 0.13
		eye_mesh.radial_segments = 8
		eye_mesh.rings = 4
		_add_mesh(root, "Eye", eye_mesh,
			Vector3(side * 0.17, 0.18, -0.45), _window_material)
	# A wedge-like cheese hat made from a low-sided yellow cylinder.
	var hat_mesh := CylinderMesh.new()
	hat_mesh.top_radius = 0.34
	hat_mesh.bottom_radius = 0.48
	hat_mesh.height = 0.34
	hat_mesh.radial_segments = 6
	_add_mesh(root, "CheeseHat", hat_mesh, Vector3(0.0, 0.58, 0.0),
		_cheese_material)


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
	_shop_material.metallic = 0.66
	_shop_material.roughness = 0.27
	_window_material = StandardMaterial3D.new()
	_window_material.albedo_color = Color(0.035, 0.075, 0.13)
	_window_material.metallic = 0.42
	_window_material.roughness = 0.14
	_cheese_material = StandardMaterial3D.new()
	_cheese_material.albedo_color = Color(1.0, 0.73, 0.12)
	_cheese_material.roughness = 0.72
	_villager_fur = StandardMaterial3D.new()
	_villager_fur.albedo_color = Color(0.45, 0.29, 0.16)
	_villager_fur.roughness = 0.86
