class_name CombatHitbox
extends Area3D
## Lightweight projectile-only hit zone. Movement keeps using the player's
## single capsule, so combat precision never changes locomotion or vine contact.

const HITBOX_LAYER := 2

var actor: Node3D
var zone := "body"


func setup(owner_actor: Node3D, hit_zone: String, radius: float) -> void:
	var sphere := SphereShape3D.new()
	sphere.radius = radius
	setup_shape(owner_actor, hit_zone, sphere)


func setup_capsule(owner_actor: Node3D, hit_zone: String, radius: float,
		height: float) -> void:
	var capsule := CapsuleShape3D.new()
	capsule.radius = radius
	capsule.height = height
	setup_shape(owner_actor, hit_zone, capsule)


func setup_shape(owner_actor: Node3D, hit_zone: String, shape: Shape3D) -> void:
	actor = owner_actor
	zone = hit_zone
	collision_layer = HITBOX_LAYER
	collision_mask = 0
	monitoring = false
	monitorable = true
	var collision := CollisionShape3D.new()
	collision.shape = shape
	add_child(collision)


func set_active(active: bool) -> void:
	collision_layer = HITBOX_LAYER if active else 0
