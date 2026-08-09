class_name MoonWorld
extends Node3D
## Deterministic playable lunar landing zone. One indexed terrain mesh and one
## height-map collider provide cratered ground; a gravity override and explicit
## character hook both use the physical 1.62 m/s² lunar acceleration.

signal actor_entered_vacuum(actor: Node3D)
signal actor_left_vacuum(actor: Node3D)
signal admin_arrived(actor: Node3D)

const LUNAR_GRAVITY := 1.62
const TERRAIN_RESOLUTION := 65
const TERRAIN_SPACING := 12.0
const TERRAIN_HALF_EXTENT := (TERRAIN_RESOLUTION - 1) * TERRAIN_SPACING * 0.5
const VACUUM_HEIGHT := 5000.0
const LANDING_XZ := Vector2(-54.0, 42.0)
const SHOP_XZ := Vector2(58.0, -32.0)
const ROCKET_ORIGIN_ABOVE_PAD := 4.40
const LUNAR_STAR_COUNT := 360
const LUNAR_ROCK_COUNT := 96

static var _surface_material: StandardMaterial3D
static var _vacuum_material: StandardMaterial3D
static var _lunar_star_material: StandardMaterial3D
static var _lunar_star_mesh: BoxMesh
static var _lunar_rock_material: StandardMaterial3D
static var _lunar_rock_mesh: SphereMesh
static var _earth_halo_material: StandardMaterial3D

var moon_seed := 404_1969
var terrain_mesh: MeshInstance3D
var terrain_body: StaticBody3D
var gravity_area: Area3D
var cheese_shop: MoonCheeseShop
var _built := false


func _ready() -> void:
	if not _built:
		setup(moon_seed)


func setup(seed_value: int) -> void:
	moon_seed = seed_value
	if _built:
		return
	_built = true
	_build_terrain()
	_build_rock_field()
	_build_gravity_volume()
	_build_lighting()
	_build_lunar_sky()
	cheese_shop = MoonCheeseShop.new()
	cheese_shop.position = Vector3(SHOP_XZ.x,
		height_at(SHOP_XZ.x, SHOP_XZ.y), SHOP_XZ.y)
	add_child(cheese_shop)
	_disable_fog_on_descendants(cheese_shop)


func gravity_at(_world_position: Vector3) -> Vector3:
	return Vector3.DOWN * LUNAR_GRAVITY


func apply_lunar_gravity(character: CharacterBody3D, delta: float) -> void:
	if is_instance_valid(character) and delta > 0.0:
		character.velocity += gravity_at(character.global_position) * delta


func height_at(local_x: float, local_z: float) -> float:
	# Broad undulation prevents a tiled look; crater centres/radii are generated
	# from stable integer hashes so server and clients produce identical ground.
	var height := sin(local_x * 0.007 + float(moon_seed % 31)) * 2.2
	height += cos(local_z * 0.009 - float(moon_seed % 47)) * 1.7
	height += sin((local_x + local_z) * 0.0045) * 2.6
	for index in range(14):
		var crater := crater_definition(index, moon_seed)
		var centre := Vector2(float(crater.x), float(crater.z))
		var radius := float(crater.radius)
		var distance := Vector2(local_x, local_z).distance_to(centre)
		if distance >= radius * 1.32:
			continue
		var normalized := distance / radius
		if normalized < 1.0:
			# Bowl reaches maximum depth at centre and eases flat at the wall.
			var bowl := 1.0 - normalized * normalized
			height -= bowl * float(crater.depth)
		else:
			# Narrow raised rim outside the bowl.
			var rim_t := (normalized - 1.0) / 0.32
			height += sin(rim_t * PI) * float(crater.depth) * 0.22
	# Keep the launch/landing pads usable without erasing nearby relief.
	for pad in [LANDING_XZ, SHOP_XZ]:
		var pad_distance := Vector2(local_x, local_z).distance_to(pad)
		if pad_distance < 18.0:
			var blend := smoothstep(18.0, 5.0, pad_distance)
			height = lerpf(height, 0.0, blend)
	return height


static func crater_definition(index: int, seed_value: int) -> Dictionary:
	var hx := _hash_u32(seed_value + index * 92821 + 17)
	var hz := _hash_u32(seed_value + index * 68917 + 71)
	var hr := _hash_u32(seed_value + index * 31337 + 193)
	var hd := _hash_u32(seed_value + index * 10103 + 389)
	return {
		"x": lerpf(-TERRAIN_HALF_EXTENT * 0.88,
			TERRAIN_HALF_EXTENT * 0.88, float(hx & 0xffff) / 65535.0),
		"z": lerpf(-TERRAIN_HALF_EXTENT * 0.88,
			TERRAIN_HALF_EXTENT * 0.88, float(hz & 0xffff) / 65535.0),
		"radius": lerpf(24.0, 92.0, float(hr & 0xffff) / 65535.0),
		"depth": lerpf(4.0, 18.0, float(hd & 0xffff) / 65535.0),
	}


static func _hash_u32(value: int) -> int:
	var x := value & 0xffffffff
	x = ((x ^ (x >> 16)) * 0x45d9f3b) & 0xffffffff
	x = ((x ^ (x >> 16)) * 0x45d9f3b) & 0xffffffff
	return (x ^ (x >> 16)) & 0xffffffff


func landing_transform() -> Transform3D:
	return Transform3D(Basis(Vector3.UP, PI), Vector3(LANDING_XZ.x,
		height_at(LANDING_XZ.x, LANDING_XZ.y) + ROCKET_ORIGIN_ABOVE_PAD,
		LANDING_XZ.y))


func actor_landing_position() -> Vector3:
	return Vector3(LANDING_XZ.x + 4.0,
		height_at(LANDING_XZ.x + 4.0, LANDING_XZ.y) + 0.8,
		LANDING_XZ.y)


func admin_teleport_actor(target: Node3D, is_authorized_admin: bool) -> bool:
	if not is_authorized_admin or not is_instance_valid(target):
		return false
	var destination := to_global(actor_landing_position())
	if target.has_method("admin_teleport"):
		target.call("admin_teleport", destination)
	else:
		target.global_position = destination
	var suit := _find_suit(target)
	# Admin travel is a complete safe path, not a debug teleport into instant
	# suffocation. Rocket passengers receive identical equipment at touchdown.
	if not suit:
		suit = SpaceSuitSystem.new()
	if not suit.equipped:
		suit.equip_for(target)
	suit.set_vacuum_exposure(true)
	admin_arrived.emit(target)
	return true


func terrain_vertex_count() -> int:
	return TERRAIN_RESOLUTION * TERRAIN_RESOLUTION


func terrain_triangle_count() -> int:
	return (TERRAIN_RESOLUTION - 1) * (TERRAIN_RESOLUTION - 1) * 2


func _build_terrain() -> void:
	_ensure_surface_material()
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var colors := PackedColorArray()
	vertices.resize(terrain_vertex_count())
	normals.resize(terrain_vertex_count())
	uvs.resize(terrain_vertex_count())
	colors.resize(terrain_vertex_count())
	var heights := PackedFloat32Array()
	heights.resize(terrain_vertex_count())
	for z_index in range(TERRAIN_RESOLUTION):
		for x_index in range(TERRAIN_RESOLUTION):
			var index := z_index * TERRAIN_RESOLUTION + x_index
			var x := (x_index - (TERRAIN_RESOLUTION - 1) * 0.5) \
				* TERRAIN_SPACING
			var z := (z_index - (TERRAIN_RESOLUTION - 1) * 0.5) \
				* TERRAIN_SPACING
			var y := height_at(x, z)
			heights[index] = y
			vertices[index] = Vector3(x, y, z)
			var dx := height_at(x + 1.0, z) - height_at(x - 1.0, z)
			var dz := height_at(x, z + 1.0) - height_at(x, z - 1.0)
			normals[index] = Vector3(-dx * 0.5, 1.0, -dz * 0.5).normalized()
			uvs[index] = Vector2(float(x_index), float(z_index)) / 8.0
			# Stable mineral/grain variation breaks up the flat white sheet while
			# normals still carry the physically important crater relief.
			var grain_hash := _hash_u32(moon_seed + x_index * 1709
				+ z_index * 3253 + 991)
			var grain := float(grain_hash & 0xff) / 255.0
			var tone := lerpf(0.38, 0.56, grain)
			colors[index] = Color(tone, tone * 0.985, tone * 0.94)
	var indices := PackedInt32Array()
	indices.resize(terrain_triangle_count() * 3)
	var write := 0
	for z_index in range(TERRAIN_RESOLUTION - 1):
		for x_index in range(TERRAIN_RESOLUTION - 1):
			var a := z_index * TERRAIN_RESOLUTION + x_index
			var b := a + 1
			var c := a + TERRAIN_RESOLUTION
			var d := c + 1
			for vertex_index in [a, b, c, b, d, c]:
				indices[write] = vertex_index
				write += 1
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	terrain_mesh = MeshInstance3D.new()
	terrain_mesh.name = "LunarTerrain"
	terrain_mesh.mesh = mesh
	terrain_mesh.material_override = _surface_material
	terrain_mesh.visibility_range_end = 2200.0
	add_child(terrain_mesh)

	var height_shape := HeightMapShape3D.new()
	height_shape.map_width = TERRAIN_RESOLUTION
	height_shape.map_depth = TERRAIN_RESOLUTION
	height_shape.map_data = heights
	var collision := CollisionShape3D.new()
	collision.name = "LunarHeightCollision"
	collision.shape = height_shape
	collision.scale = Vector3(TERRAIN_SPACING, 1.0, TERRAIN_SPACING)
	terrain_body = StaticBody3D.new()
	terrain_body.name = "LunarGround"
	terrain_body.collision_layer = 1
	terrain_body.collision_mask = 1
	terrain_body.add_child(collision)
	# The landing core is intentionally flat in height_at(). Give that critical
	# spawn area a simple convex contact as well: convex sweeps are the most
	# reliable way to recover a small CharacterBody immediately after a remote
	# realm teleport, before it starts walking onto the surrounding terrain.
	var landing_contact := CollisionShape3D.new()
	landing_contact.name = "LunarLandingPadContact"
	var landing_cylinder := CylinderShape3D.new()
	landing_cylinder.radius = 6.0
	landing_cylinder.height = 1.0
	landing_contact.shape = landing_cylinder
	landing_contact.position = Vector3(LANDING_XZ.x, -0.5, LANDING_XZ.y)
	terrain_body.add_child(landing_contact)
	add_child(terrain_body)


func _build_rock_field() -> void:
	# One deterministic MultiMesh scatters low-poly ejecta and boulders around
	# crater rims. It adds close-range scale without spawning or updating dozens
	# of independent nodes.
	_ensure_lunar_sky_resources()
	var rocks := MultiMeshInstance3D.new()
	rocks.name = "LunarEjectaBoulders"
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.use_colors = true
	multimesh.mesh = _lunar_rock_mesh
	multimesh.instance_count = LUNAR_ROCK_COUNT
	for index in range(LUNAR_ROCK_COUNT):
		var hx := _hash_u32(moon_seed + index * 2719 + 43)
		var hz := _hash_u32(moon_seed + index * 4517 + 101)
		var hs := _hash_u32(moon_seed + index * 6991 + 229)
		var x := lerpf(-TERRAIN_HALF_EXTENT * 0.92,
			TERRAIN_HALF_EXTENT * 0.92, float(hx & 0xffff) / 65535.0)
		var z := lerpf(-TERRAIN_HALF_EXTENT * 0.92,
			TERRAIN_HALF_EXTENT * 0.92, float(hz & 0xffff) / 65535.0)
		# Keep both authored pads clear. Deterministically mirror any would-be
		# obstruction instead of a variable-length rejection loop.
		for pad in [LANDING_XZ, SHOP_XZ]:
			if Vector2(x, z).distance_to(pad) < 21.0:
				x = -x
				z = -z
		var size := lerpf(0.35, 2.1, pow(float(hs & 0xff) / 255.0, 2.2))
		var yaw := float((hs >> 8) & 0xffff) / 65535.0 * TAU
		var squash := lerpf(0.42, 0.76, float((hs >> 24) & 0xff) / 255.0)
		var basis := Basis(Vector3.UP, yaw).scaled(
			Vector3(size, size * squash, size * 0.78))
		var origin := Vector3(x, height_at(x, z) + size * squash * 0.32, z)
		multimesh.set_instance_transform(index, Transform3D(basis, origin))
		var tint := lerpf(0.58, 0.84, float((hs >> 16) & 0xff) / 255.0)
		multimesh.set_instance_color(index,
			Color(tint, tint * 0.98, tint * 0.93))
	rocks.multimesh = multimesh
	rocks.material_override = _lunar_rock_material
	rocks.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	rocks.visibility_range_end = 900.0
	add_child(rocks)


func _build_gravity_volume() -> void:
	gravity_area = Area3D.new()
	gravity_area.name = "LunarVacuumAndGravity"
	gravity_area.gravity_space_override = Area3D.SPACE_OVERRIDE_REPLACE
	gravity_area.gravity_point = false
	gravity_area.gravity_direction = Vector3.DOWN
	gravity_area.gravity = LUNAR_GRAVITY
	gravity_area.monitoring = true
	gravity_area.collision_layer = 0
	gravity_area.collision_mask = 1
	var shape_node := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(TERRAIN_HALF_EXTENT * 2.0, VACUUM_HEIGHT,
		TERRAIN_HALF_EXTENT * 2.0)
	shape_node.shape = box
	shape_node.position.y = VACUUM_HEIGHT * 0.5 - 100.0
	gravity_area.add_child(shape_node)
	gravity_area.body_entered.connect(_on_body_entered)
	gravity_area.body_exited.connect(_on_body_exited)
	add_child(gravity_area)


func _build_lighting() -> void:
	var sunlight := DirectionalLight3D.new()
	sunlight.name = "HarshLunarSunlight"
	sunlight.light_color = Color(1.0, 0.94, 0.82)
	sunlight.light_energy = 0.62
	# Earth's celestial sun already supplies the single shadow pass in both
	# realms. Keep this as warm lunar fill so the hidden Moon never doubles the
	# directional shadow cost, and so there are not two conflicting "suns" after
	# touchdown.
	sunlight.shadow_enabled = false
	sunlight.rotation_degrees = Vector3(-52.0, -28.0, 0.0)
	add_child(sunlight)


func _build_lunar_sky() -> void:
	_ensure_lunar_sky_resources()
	# An inward-facing dark shell replaces Earth's atmospheric sky only while the
	# MoonWorld is visible. One bounded MultiMesh supplies sharp airless stars.
	var vacuum_mesh := SphereMesh.new()
	vacuum_mesh.radius = 1750.0
	vacuum_mesh.height = 3500.0
	vacuum_mesh.radial_segments = 48
	vacuum_mesh.rings = 24
	var vacuum := MeshInstance3D.new()
	vacuum.name = "AirlessBlackSky"
	vacuum.mesh = vacuum_mesh
	vacuum.material_override = _vacuum_material
	vacuum.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(vacuum)

	var stars := MultiMeshInstance3D.new()
	stars.name = "LunarStarField"
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.use_colors = true
	multimesh.mesh = _lunar_star_mesh
	multimesh.instance_count = LUNAR_STAR_COUNT
	for index in range(LUNAR_STAR_COUNT):
		var direction := _fibonacci_direction(index, LUNAR_STAR_COUNT)
		var hash := _hash_u32(moon_seed + index * 3571 + 211)
		var radius := 1080.0 + float(hash & 0xffff) / 65535.0 * 560.0
		var sparkle := 0.65 + float((hash >> 16) & 0xff) / 255.0 * 1.6
		multimesh.set_instance_transform(index, Transform3D(
			Basis.IDENTITY.scaled(Vector3.ONE * sparkle), direction * radius))
		multimesh.set_instance_color(index, Color(
			0.72 + sparkle * 0.10, 0.82 + sparkle * 0.06, 1.0))
	stars.multimesh = multimesh
	stars.material_override = _lunar_star_material
	stars.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(stars)

	# A textured Earth hangs above the landing site. It is intentionally a little
	# larger than strict angular scale so players can read continents and cloud
	# bands without a telescope.
	var earth_mesh := SphereMesh.new()
	earth_mesh.radius = 74.0
	earth_mesh.height = 148.0
	earth_mesh.radial_segments = 48
	earth_mesh.rings = 24
	var earth_material := StandardMaterial3D.new()
	earth_material.albedo_color = Color.WHITE
	earth_material.albedo_texture = SpaceVoyageVisuals.shared_earth_texture()
	earth_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	earth_material.disable_fog = true
	var earth := MeshInstance3D.new()
	earth.name = "EarthAboveTheMoon"
	earth.mesh = earth_mesh
	earth.material_override = earth_material
	earth.position = Vector3(-760.0, 560.0, -1210.0)
	earth.rotation.y = -0.45
	earth.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(earth)
	var halo_mesh := SphereMesh.new()
	halo_mesh.radius = 79.0
	halo_mesh.height = 158.0
	halo_mesh.radial_segments = 40
	halo_mesh.rings = 20
	var halo := MeshInstance3D.new()
	halo.name = "EarthAtmosphereHalo"
	halo.mesh = halo_mesh
	halo.material_override = _earth_halo_material
	halo.position = earth.position
	halo.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(halo)


static func _fibonacci_direction(index: int, count: int) -> Vector3:
	var y := 1.0 - (float(index) + 0.5) * 2.0 / float(count)
	var radial := sqrt(maxf(0.0, 1.0 - y * y))
	var angle := float(index) * 2.399963229728653
	return Vector3(cos(angle) * radial, y, sin(angle) * radial)


static func _ensure_lunar_sky_resources() -> void:
	if _vacuum_material:
		return
	_vacuum_material = StandardMaterial3D.new()
	_vacuum_material.albedo_color = Color(0.0015, 0.0025, 0.007)
	_vacuum_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_vacuum_material.cull_mode = BaseMaterial3D.CULL_FRONT
	_vacuum_material.disable_receive_shadows = true
	_vacuum_material.disable_fog = true
	_lunar_star_mesh = BoxMesh.new()
	_lunar_star_mesh.size = Vector3(0.90, 0.90, 0.90)
	_lunar_star_material = StandardMaterial3D.new()
	_lunar_star_material.albedo_color = Color.WHITE
	_lunar_star_material.emission_enabled = true
	_lunar_star_material.emission = Color(0.72, 0.84, 1.0)
	_lunar_star_material.emission_energy_multiplier = 4.2
	_lunar_star_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_lunar_star_material.vertex_color_use_as_albedo = true
	_lunar_star_material.disable_fog = true
	_lunar_rock_mesh = SphereMesh.new()
	_lunar_rock_mesh.radius = 0.5
	_lunar_rock_mesh.height = 1.0
	_lunar_rock_mesh.radial_segments = 8
	_lunar_rock_mesh.rings = 4
	_lunar_rock_material = StandardMaterial3D.new()
	_lunar_rock_material.albedo_color = Color(0.43, 0.42, 0.40)
	_lunar_rock_material.roughness = 1.0
	_lunar_rock_material.vertex_color_use_as_albedo = true
	_lunar_rock_material.disable_fog = true
	_earth_halo_material = StandardMaterial3D.new()
	_earth_halo_material.albedo_color = Color(0.12, 0.48, 1.0, 0.16)
	_earth_halo_material.emission_enabled = true
	_earth_halo_material.emission = Color(0.08, 0.30, 0.88)
	_earth_halo_material.emission_energy_multiplier = 1.8
	_earth_halo_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_earth_halo_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	# Render only the far side of the shell. The opaque Earth hides the centre,
	# leaving a thin atmospheric limb instead of a blue bubble over continents.
	_earth_halo_material.cull_mode = BaseMaterial3D.CULL_FRONT
	_earth_halo_material.disable_fog = true


func _on_body_entered(body: Node3D) -> void:
	var suit := _find_suit(body)
	if suit:
		suit.set_vacuum_exposure(true)
	actor_entered_vacuum.emit(body)


func _on_body_exited(body: Node3D) -> void:
	var suit := _find_suit(body)
	if suit:
		suit.set_vacuum_exposure(false)
	actor_left_vacuum.emit(body)


static func _find_suit(actor: Node) -> SpaceSuitSystem:
	if not is_instance_valid(actor):
		return null
	if actor is SpaceSuitSystem:
		return actor as SpaceSuitSystem
	var candidate := actor.get_node_or_null("SpaceSuitSystem")
	return candidate as SpaceSuitSystem if candidate is SpaceSuitSystem else null


static func _disable_fog_on_descendants(root: Node) -> void:
	for child in root.get_children():
		if child is MeshInstance3D:
			var material := (child as MeshInstance3D).material_override
			if material is BaseMaterial3D:
				(material as BaseMaterial3D).disable_fog = true
		_disable_fog_on_descendants(child)


static func _ensure_surface_material() -> void:
	if _surface_material:
		return
	_surface_material = StandardMaterial3D.new()
	_surface_material.albedo_color = Color(0.50, 0.50, 0.48)
	_surface_material.roughness = 0.96
	_surface_material.metallic = 0.03
	_surface_material.vertex_color_use_as_albedo = true
	_surface_material.disable_fog = true
