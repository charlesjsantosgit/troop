class_name PracticeTarget
extends StaticBody3D
## Reactive jungle shooting target. It folds away briefly when struck, then
## resets so it can be practiced on indefinitely.

var _active := true
var _rest_rotation := Vector3.ZERO


func setup(pos: Vector3, look_target: Vector3) -> void:
	global_position = pos
	look_at(Vector3(look_target.x, pos.y, look_target.z), Vector3.UP)
	_rest_rotation = rotation


func _ready() -> void:
	var wood := StandardMaterial3D.new()
	wood.albedo_color = Color(0.25, 0.105, 0.025)
	wood.roughness = 0.88
	var yellow := StandardMaterial3D.new()
	yellow.albedo_color = Color(0.98, 0.70, 0.05)
	yellow.emission_enabled = true
	yellow.emission = Color(0.28, 0.12, 0.0)
	var red := StandardMaterial3D.new()
	red.albedo_color = Color(0.85, 0.10, 0.045)
	red.emission_enabled = true
	red.emission = Color(0.3, 0.01, 0.0)

	var pole := MeshInstance3D.new()
	var pole_mesh := CylinderMesh.new()
	pole_mesh.top_radius = 0.07
	pole_mesh.bottom_radius = 0.10
	pole_mesh.height = 2.1
	pole_mesh.radial_segments = 8
	pole.mesh = pole_mesh
	pole.material_override = wood
	pole.position = Vector3(0, 1.05, 0.12)
	add_child(pole)

	var board := MeshInstance3D.new()
	var board_mesh := CylinderMesh.new()
	board_mesh.top_radius = 0.58
	board_mesh.bottom_radius = 0.58
	board_mesh.height = 0.12
	board_mesh.radial_segments = 18
	board.mesh = board_mesh
	board.material_override = yellow
	board.rotation.x = PI * 0.5
	board.position = Vector3(0, 1.85, 0)
	add_child(board)

	var center := MeshInstance3D.new()
	var center_mesh := CylinderMesh.new()
	center_mesh.top_radius = 0.20
	center_mesh.bottom_radius = 0.20
	center_mesh.height = 0.135
	center_mesh.radial_segments = 16
	center.mesh = center_mesh
	center.material_override = red
	center.rotation.x = PI * 0.5
	center.position = Vector3(0, 1.85, -0.015)
	add_child(center)

	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(1.18, 1.18, 0.18)
	collision.shape = shape
	collision.position = Vector3(0, 1.85, 0)
	add_child(collision)


func take_damage(_amount: float, _source: Node3D, _impulse: Vector3) -> void:
	if not _active:
		return
	_active = false
	collision_layer = 0
	Sfx.play_at("target_hit", global_position + Vector3.UP * 1.8, -5.0)
	var tween := create_tween()
	tween.set_trans(Tween.TRANS_BACK)
	tween.set_ease(Tween.EASE_OUT)
	tween.tween_property(self, "rotation:x", _rest_rotation.x + PI * 0.48, 0.22)
	tween.tween_interval(0.7)
	tween.set_trans(Tween.TRANS_QUAD)
	tween.tween_property(self, "rotation", _rest_rotation, 0.28)
	tween.tween_callback(_reset_target)


func _reset_target() -> void:
	_active = true
	collision_layer = 1
