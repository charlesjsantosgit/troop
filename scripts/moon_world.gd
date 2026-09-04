class_name MoonWorld
extends Node3D
## Closed, deterministic lunar world. A welded cubed sphere supplies the exact
## same terrain to rendering, collision and spawn queries. The compact gameplay
## radius allows a complete trip around the Moon without floating-point drift;
## astronomical dimensions remain available to the orbital voyage.

signal actor_entered_vacuum(actor: Node3D)
signal actor_left_vacuum(actor: Node3D)
signal admin_arrived(actor: Node3D)

const LUNAR_GRAVITY := 1.62
const CHARACTER_SAFE_MARGIN := 0.02
const MOON_DIAMETER_KM := 3_474.8
const MOON_RADIUS_KM := MOON_DIAMETER_KM * 0.5
const MOON_RADIUS_METERS := MOON_RADIUS_KM * 1000.0
const PLAYABLE_RADIUS_METERS := 450.0
const PLAYABLE_CENTER := Vector3(-54.0, -PLAYABLE_RADIUS_METERS, 42.0)
const SPHERE_FACE_SEGMENTS := 64
const SPHERE_CRATER_COUNT := 84
const TERRAIN_RESOLUTION := 65
const TERRAIN_SPACING := 12.0
const TERRAIN_HALF_EXTENT := (TERRAIN_RESOLUTION - 1) * TERRAIN_SPACING * 0.5
const HORIZON_HALF_EXTENT := 140_000.0
const HORIZON_EDGE_SEGMENTS := 192
const HORIZON_GRID_RESOLUTION := 97
const CAP_INNER_RINGS := 32
const CAP_MIDDLE_RINGS := 24
const CAP_OUTER_RINGS := 40
const CAP_RADIAL_RINGS := CAP_INNER_RINGS + CAP_MIDDLE_RINGS + CAP_OUTER_RINGS
const VACUUM_HEIGHT := 5000.0
const LANDING_XZ := Vector2(-54.0, 42.0)
const SHOP_XZ := Vector2(58.0, -32.0)
const ROCKET_ORIGIN_ABOVE_PAD := 13.0
const LANDING_PLATFORM_RADIUS := 7.5
const LANDING_PLATFORM_THICKNESS := 0.45
const LUNAR_ROCK_COUNT := 96

static var _surface_shader: Shader
var _horizon_material: ShaderMaterial
static var _lunar_rock_material: StandardMaterial3D
static var _lunar_rock_mesh: SphereMesh
static var _lunar_rock_vertices := PackedVector3Array()
static var LUNAR_MICRODETAIL: Texture2D:
	get:
		return SharedTextureCache.get_texture(SharedTextureCache.MICRODETAIL_PATH)

const LUNAR_CAP_SHADER := """
shader_type spatial;
render_mode fog_disabled;

uniform sampler2D lunar_atlas : source_color, repeat_enable,
    filter_linear_mipmap_anisotropic;
uniform sampler2D lunar_microdetail : source_color, repeat_enable,
    filter_linear_mipmap_anisotropic;
uniform sampler2DArray terrain_radii : filter_linear, repeat_disable;
uniform float terrain_grid_segments = 64.0;
uniform float scaled_space_active : hint_range(0.0, 1.0) = 0.0;
uniform float scaled_cap_retraction : hint_range(0.0, 1.0) = 0.0;
uniform vec3 playable_center = vec3(0.0);
uniform float playable_radius = 1.0;
uniform vec3 scaled_surface_local = vec3(0.0);
uniform float scaled_moon_radius = 1.0;
uniform vec3 lunar_sun_direction = vec3(-0.29, 0.78, -0.55);
varying vec3 ground_position;
varying vec3 ground_world_position;
varying vec3 surface_normal;
varying vec3 radial_normal;
varying vec4 mineral_tint;
varying vec3 sun_local;
varying float relief_depth;

void vertex() {
    vec3 radial = normalize(VERTEX - playable_center);
    ground_position = VERTEX - playable_center;
    surface_normal = NORMAL;
    radial_normal = radial;
    mineral_tint = COLOR;
    sun_local = normalize(inverse(mat3(MODEL_MATRIX)) * lunar_sun_direction);
    float relief = length(VERTEX - playable_center) - playable_radius;
    relief_depth = max(0.0, -relief - 0.8);
    vec3 scaled_centre = scaled_surface_local
        - vec3(0.0, scaled_moon_radius, 0.0);
    float inward_bias = smoothstep(0.80, 1.0, scaled_cap_retraction)
        * max(0.015, scaled_moon_radius * 0.001);
    vec3 scaled_vertex = scaled_centre + radial
        * (scaled_moon_radius + relief * scaled_moon_radius / playable_radius
            - inward_bias);
    VERTEX = mix(VERTEX, scaled_vertex, scaled_space_active);
    ground_world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

float surface_radius(vec3 d) {
    vec3 a=abs(d);
    vec2 uv;
    float face;
    if (a.x>=a.y && a.x>=a.z) {
        face=d.x>=0.0 ? 0.0 : 1.0;
        uv=vec2(d.x>=0.0 ? -d.z : d.z,d.y)/a.x;
    } else if (a.y>=a.z) {
        face=d.y>=0.0 ? 2.0 : 3.0;
        uv=vec2(d.x,d.y>=0.0 ? -d.z : d.z)/a.y;
    } else {
        face=d.z>=0.0 ? 4.0 : 5.0;
        uv=vec2(d.z>=0.0 ? d.x : -d.x,d.y)/a.z;
    }
    uv=((uv*0.5+0.5)*terrain_grid_segments+0.5)/(terrain_grid_segments+1.0);
    return texture(terrain_radii,vec3(uv,face)).r;
}
float terrain_sun_visibility(vec3 origin,vec3 normal,vec3 sun) {
    float elevation=dot(normalize(origin),sun);
    if (elevation<=-0.025) { return 0.0; }
    if (elevation>0.55) { return 1.0; }
    // Ten bounded samples of the same welded height grid as collision/rendering.
    // Curvature is included in ray radius, so the rim shadow follows the Sun
    // and cannot make another coplanar surface or a shadow-map contour ring.
    float visibility=1.0;
    for (int i=0;i<10;i++) {
        float distance_along=2.0*pow(1.62,float(i));
        vec3 ray=origin+normalize(origin)*0.32+sun*distance_along;
        float clearance=length(ray)-surface_radius(normalize(ray));
        float penumbra=max(0.08,distance_along*0.00465);
        visibility=min(visibility,smoothstep(-penumbra,penumbra,clearance));
    }
    return visibility;
}

void fragment() {
    vec3 radial = normalize(radial_normal);
    vec3 atlas_direction = vec3(radial.x, radial.z, -radial.y);
    vec2 atlas_uv = vec2(fract(atan(atlas_direction.x,
        atlas_direction.z) / 6.28318530718),
        acos(clamp(atlas_direction.y, -1.0, 1.0)) / 3.14159265359);
    vec3 macro_colour = texture(lunar_atlas, atlas_uv).rgb;
    // Decide whether grain contributes before doing any texture work. Explicit
    // gradients remain valid at the dynamic branch boundary and retain the
    // same anisotropic mip selection as the original unconditional samples.
    vec3 ground_dx = dFdx(ground_position) / 3.0;
    vec3 ground_dy = dFdy(ground_position) / 3.0;
    float grain_footprint = max(length(ground_dx), length(ground_dy));
    float derivative_visibility = 1.0 - smoothstep(0.003, 0.012, grain_footprint);
    float distance_visibility = 1.0 - smoothstep(4.0, 16.0,
        distance(CAMERA_POSITION_WORLD, ground_world_position));
    float grain_visibility = derivative_visibility * distance_visibility;
    float grain = 0.65;
    if (grain_visibility > 0.0) {
        // Triplanar regolith has no UV seam at poles or cube-face edges.
        vec3 weights = radial * radial;
        weights *= weights;
        weights /= max(weights.x + weights.y + weights.z, 0.0001);
        float sampled_grain = textureGrad(lunar_microdetail,
                ground_position.yz / 3.0, ground_dx.yz, ground_dy.yz).r * weights.x
            + textureGrad(lunar_microdetail,
                ground_position.xz / 3.0, ground_dx.xz, ground_dy.xz).r * weights.y
            + textureGrad(lunar_microdetail,
                ground_position.xy / 3.0, ground_dx.xy, ground_dy.xy).r * weights.z;
        grain = mix(0.65, sampled_grain, grain_visibility);
    }
    vec3 regolith = mix(vec3(0.38, 0.365, 0.345), macro_colour, 0.06);
    vec3 local_colour = regolith * mix(0.92, 1.06, grain) * mineral_tint.rgb;
    float orbital_weight = smoothstep(0.10, 0.75, scaled_cap_retraction);
    // The physical sphere deliberately does not cast onto itself (cascade acne).
    // Preserve long-distance crater relief independently of those short shadows:
    // opposing walls retain their slope lighting and low-Sun bowls retain shade.
    vec3 terrain_normal = normalize(surface_normal);
    vec3 local_sun = normalize(sun_local);
    float terrain_solar = dot(terrain_normal, local_sun);
    float cavity = smoothstep(0.3, 7.5, relief_depth);
    float sun_visibility=terrain_sun_visibility(ground_position,terrain_normal,local_sun);
    float relief_light=mix(0.15,1.0,sun_visibility)*(1.0-cavity*0.08);
    ALBEDO = local_colour * relief_light * (1.0 - orbital_weight);
    // Orbital compression also retains a terminator and crater relief instead
    // of turning the entire lunar surface into a uniformly emissive photograph.
    float orbital_sun = 0.055 + 0.945 * smoothstep(-0.015, 0.45, terrain_solar);
    EMISSION = macro_colour * relief_light * orbital_sun * orbital_weight;
    ROUGHNESS = mix(0.92, 0.99, grain);
    SPECULAR = 0.08;
    AO = mix(0.91, 1.0, grain) * (1.0 - cavity * 0.30);
    AO_LIGHT_AFFECT = 0.36;
}
"""

var moon_seed := 404_1969
var terrain_mesh: MeshInstance3D
var terrain_body: StaticBody3D
var landing_platform: MeshInstance3D
var landing_platform_body: StaticBody3D
var lunar_visual_horizon: MeshInstance3D
var lunar_far_surface_fill: MeshInstance3D
var gravity_area: Area3D
var lunar_environment: Environment
var lunar_sky: LunarSky
var _sunlight: DirectionalLight3D
var _lunar_sun_direction := Vector3(-0.29, 0.78, -0.55).normalized()
var cheese_shop: MoonCheeseShop
var colony_world: MoonColonyWorld
var _built := false
var _crater_seed := -1
var _crater_directions := PackedVector3Array()
var _crater_radii := PackedFloat32Array()
var _crater_depths := PackedFloat32Array()
var _crater_cutoffs := PackedFloat32Array()
var _relief_images: Array[Image] = []
var _relief_texture: Texture2DArray
var _sphere_vertices := PackedVector3Array()
var _sphere_indices := PackedInt32Array()
var _grid_vertex_indices: Dictionary = {}

enum SetupPhase {
	NOT_STARTED, MATERIAL, VERTEX_ROWS, INDEX_ROWS, FACE_NORMALS,
	VERTEX_NORMALS, TERRAIN_MESH, TERRAIN_COLLISION_FACES, TERRAIN_COLLISION, LANDING_PLATFORM,
	ROCKS, GRAVITY, LIGHTING, SKY, SHOP, COLONY, COMPLETE,
}
const SETUP_NORMAL_TRIANGLE_BATCH := 512
const SETUP_NORMAL_VERTEX_BATCH := 1024
const SETUP_COLLISION_TRIANGLE_BATCH := 512
# Match Godot's TriangleMesh::create, used by Mesh.create_trimesh_shape().
const TERRAIN_COLLISION_SNAP := 0.0001
var _setup_phase := SetupPhase.NOT_STARTED
var _setup_face := 0
var _setup_row := 0
var _setup_cursor := 0
var _setup_normals := PackedVector3Array()
var _setup_colors := PackedColorArray()
var _setup_collision_faces := PackedVector3Array()


func _ready() -> void:
	# An explicit progressive build is owned by its caller, even after this node
	# enters the tree. Never drain it from _ready and recreate the entry hitch.
	if not _built and _setup_phase == SetupPhase.NOT_STARTED:
		setup(moon_seed)


func setup(seed_value: int) -> void:
	if _setup_phase != SetupPhase.NOT_STARTED and not _built:
		# Switching APIs mid-build completes the already selected seed; restarting
		# would mix cached crater samples and the partially welded terrain.
		while not build_setup_step():
			if is_queued_for_deletion():
				return
		return
	moon_seed = seed_value
	if _built:
		return
	_built = true
	_build_terrain()
	_build_landing_platform()
	_build_rock_field()
	_build_gravity_volume()
	_build_lighting()
	_build_lunar_sky()
	cheese_shop = MoonCheeseShop.new()
	cheese_shop.transform = shop_local_transform()
	add_child(cheese_shop)
	_disable_fog_on_descendants(cheese_shop)
	colony_world = MoonColonyWorld.new()
	colony_world.configure(self)
	add_child(colony_world)
	_disable_fog_on_descendants(colony_world)
	_setup_phase = SetupPhase.COMPLETE


## Select a seed without constructing resources or scheduling background work.
## Keep the node hidden/disabled until completion; callers may free it at any
## point. Repeated begin calls do not reseed an in-progress or completed world.
func begin_setup(seed_value: int) -> void:
	if _built or _setup_phase != SetupPhase.NOT_STARTED:
		return
	moon_seed = seed_value
	_setup_phase = SetupPhase.MATERIAL


func is_setup_complete() -> bool:
	return _built


func setup_phase_name() -> String:
	return str(SetupPhase.keys()[_setup_phase]).to_lower()


## Terrain CPU work is sliced by rows or small normal/collision-face batches, checked
## against elapsed wall time after every unit. Native mesh/collider publication
## and each authored feature get a separate call: those atomic engine calls can
## exceed the requested budget, but never share a burst with the next feature.
func build_setup_step(budget_usec: int = 2000) -> bool:
	if _built:
		return true
	if is_queued_for_deletion():
		return false
	if _setup_phase == SetupPhase.NOT_STARTED:
		begin_setup(moon_seed)
	var started := Time.get_ticks_usec()
	while true:
		var previous_phase := _setup_phase
		_build_setup_unit()
		if _built:
			return true
		var previous_was_cpu := (previous_phase >= SetupPhase.VERTEX_ROWS \
			and previous_phase <= SetupPhase.VERTEX_NORMALS) \
			or previous_phase == SetupPhase.TERRAIN_COLLISION_FACES
		var next_is_cpu := (_setup_phase >= SetupPhase.VERTEX_ROWS \
			and _setup_phase <= SetupPhase.VERTEX_NORMALS) \
			or _setup_phase == SetupPhase.TERRAIN_COLLISION_FACES
		if not previous_was_cpu or not next_is_cpu \
				or Time.get_ticks_usec() - started >= maxi(budget_usec, 1):
			return false
	return false


func _build_setup_unit() -> void:
	match _setup_phase:
		SetupPhase.MATERIAL:
			_ensure_surface_material()
			_setup_phase = SetupPhase.VERTEX_ROWS
		SetupPhase.VERTEX_ROWS:
			_build_setup_vertex_row()
		SetupPhase.INDEX_ROWS:
			_build_setup_index_row()
		SetupPhase.FACE_NORMALS:
			var stop := mini(_setup_cursor + SETUP_NORMAL_TRIANGLE_BATCH * 3,
				_sphere_indices.size())
			for index in range(_setup_cursor, stop, 3):
				var a := _sphere_indices[index]
				var b := _sphere_indices[index + 1]
				var c := _sphere_indices[index + 2]
				var normal := (_sphere_vertices[c] - _sphere_vertices[a]).cross(
					_sphere_vertices[b] - _sphere_vertices[a])
				_setup_normals[a] += normal
				_setup_normals[b] += normal
				_setup_normals[c] += normal
			_setup_cursor = stop
			if stop == _sphere_indices.size():
				_setup_cursor = 0
				_setup_phase = SetupPhase.VERTEX_NORMALS
		SetupPhase.VERTEX_NORMALS:
			var stop := mini(_setup_cursor + SETUP_NORMAL_VERTEX_BATCH,
				_setup_normals.size())
			for index in range(_setup_cursor, stop):
				_setup_normals[index] = _setup_normals[index].normalized()
			_setup_cursor = stop
			if stop == _setup_normals.size():
				_setup_phase = SetupPhase.TERRAIN_MESH
		SetupPhase.TERRAIN_MESH:
			_publish_setup_terrain()
			_setup_cursor = 0
			_setup_collision_faces.resize(_sphere_indices.size())
			_setup_phase = SetupPhase.TERRAIN_COLLISION_FACES
		SetupPhase.TERRAIN_COLLISION_FACES:
			# Retain the engine trimesh path's triangle order and vertex snapping,
			# without reading the published terrain buffers back from the GPU.
			var stop := mini(_setup_cursor + SETUP_COLLISION_TRIANGLE_BATCH * 3,
				_sphere_indices.size())
			for index in range(_setup_cursor, stop):
				_setup_collision_faces[index] = _sphere_vertices[_sphere_indices[index]] \
					.snappedf(TERRAIN_COLLISION_SNAP)
			_setup_cursor = stop
			if stop == _sphere_indices.size():
				_setup_phase = SetupPhase.TERRAIN_COLLISION
		SetupPhase.TERRAIN_COLLISION:
			terrain_body = StaticBody3D.new()
			terrain_body.name = "ClosedLunarGround"
			terrain_body.collision_layer = 1
			terrain_body.collision_mask = 1
			var collision := CollisionShape3D.new()
			collision.name = "ExactSphericalTerrainCollision"
			var shape := ConcavePolygonShape3D.new()
			shape.set_faces(_setup_collision_faces)
			collision.shape = shape
			terrain_body.add_child(collision)
			add_child(terrain_body)
			_setup_collision_faces = PackedVector3Array()
			_setup_phase = SetupPhase.LANDING_PLATFORM
		SetupPhase.LANDING_PLATFORM:
			_build_landing_platform()
			_setup_phase = SetupPhase.ROCKS
		SetupPhase.ROCKS:
			_build_rock_field()
			_setup_phase = SetupPhase.GRAVITY
		SetupPhase.GRAVITY:
			_build_gravity_volume()
			_setup_phase = SetupPhase.LIGHTING
		SetupPhase.LIGHTING:
			_build_lighting()
			_setup_phase = SetupPhase.SKY
		SetupPhase.SKY:
			_build_lunar_sky()
			_setup_phase = SetupPhase.SHOP
		SetupPhase.SHOP:
			cheese_shop = MoonCheeseShop.new()
			cheese_shop.transform = shop_local_transform()
			add_child(cheese_shop)
			_disable_fog_on_descendants(cheese_shop)
			_setup_phase = SetupPhase.COLONY
		SetupPhase.COLONY:
			colony_world = MoonColonyWorld.new()
			colony_world.configure(self)
			add_child(colony_world)
			_disable_fog_on_descendants(colony_world)
			_setup_phase = SetupPhase.COMPLETE
			_built = true


func _build_setup_vertex_row() -> void:
	# Preserve the synchronous face/row/column order, including edge welding.
	for x in range(SPHERE_FACE_SEGMENTS + 1):
		var key := _cube_grid_point(_setup_face, x, _setup_row)
		var point := _grid_surface_vertex(_setup_face, x, _setup_row)
		_store_relief_height(_setup_face, x, _setup_row, point)
		if _grid_vertex_indices.has(key):
			continue
		_grid_vertex_indices[key] = _sphere_vertices.size()
		_sphere_vertices.append(point)
		_setup_normals.append(Vector3.ZERO)
		var mineral := 0.97 + 0.035 * sin(point.x * 0.017 + point.z * 0.011)
		_setup_colors.append(Color(mineral, mineral * 0.99, mineral * 0.96))
	_setup_row += 1
	if _setup_row > SPHERE_FACE_SEGMENTS:
		_setup_row = 0
		_setup_phase = SetupPhase.INDEX_ROWS


func _build_setup_index_row() -> void:
	for x in range(SPHERE_FACE_SEGMENTS):
		var a: int = _grid_vertex_indices[_cube_grid_point(_setup_face, x, _setup_row)]
		var b: int = _grid_vertex_indices[_cube_grid_point(_setup_face, x + 1, _setup_row)]
		var c: int = _grid_vertex_indices[_cube_grid_point(_setup_face, x, _setup_row + 1)]
		var d: int = _grid_vertex_indices[_cube_grid_point(_setup_face, x + 1, _setup_row + 1)]
		_sphere_indices.append_array(PackedInt32Array([a, c, b, b, c, d]))
	_setup_row += 1
	if _setup_row == SPHERE_FACE_SEGMENTS:
		_setup_row = 0
		_setup_face += 1
		_setup_phase = SetupPhase.VERTEX_ROWS if _setup_face < 6 \
			else SetupPhase.FACE_NORMALS


func _publish_setup_terrain() -> void:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = _sphere_vertices
	arrays[Mesh.ARRAY_NORMAL] = _setup_normals
	arrays[Mesh.ARRAY_COLOR] = _setup_colors
	arrays[Mesh.ARRAY_INDEX] = _sphere_indices
	_publish_relief_texture()
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	terrain_mesh = MeshInstance3D.new()
	terrain_mesh.name = "ClosedLunarSphere"
	terrain_mesh.mesh = mesh
	terrain_mesh.material_override = _horizon_material
	terrain_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	terrain_mesh.extra_cull_margin = 0.0
	add_child(terrain_mesh)
	lunar_far_surface_fill = terrain_mesh
	lunar_visual_horizon = terrain_mesh
	_setup_normals = PackedVector3Array()
	_setup_colors = PackedColorArray()


func center_world_position() -> Vector3:
	return to_global(PLAYABLE_CENTER)


func radial_up_at(world_position: Vector3) -> Vector3:
	var radial := world_position - center_world_position()
	return radial.normalized() if radial.length_squared() > 0.000001 \
		else global_basis.y.normalized()


func gravity_at(world_position: Vector3) -> Vector3:
	return -radial_up_at(world_position) * LUNAR_GRAVITY


func apply_lunar_gravity(character: CharacterBody3D, delta: float) -> void:
	if is_instance_valid(character) and delta > 0.0:
		# The Moon realm is far above Earth; a 1 mm margin is smaller than the
		# float32 position step there and can turn a southern-floor contact into
		# an inward ceiling normal. Keep generic actor hooks equally robust.
		character.safe_margin = maxf(character.safe_margin, CHARACTER_SAFE_MARGIN)
		character.up_direction = radial_up_at(character.global_position)
		character.velocity += gravity_at(character.global_position) * delta


## Local point on the actual collision triangles, with radial clearance. A
## direction works on all six faces and at both poles without a longitude seam.
func surface_position(direction: Vector3, altitude: float = 0.0) -> Vector3:
	var radial := direction.normalized() if direction.length_squared() > 0.000001 \
		else Vector3.UP
	var grid := _direction_grid(radial)
	var face := int(grid.x)
	var grid_x := clampf(grid.y, 0.0, float(SPHERE_FACE_SEGMENTS))
	var grid_y := clampf(grid.z, 0.0, float(SPHERE_FACE_SEGMENTS))
	var ix := mini(int(grid_x), SPHERE_FACE_SEGMENTS - 1)
	var iy := mini(int(grid_y), SPHERE_FACE_SEGMENTS - 1)
	var fx := grid_x - float(ix)
	var fy := grid_y - float(iy)
	var a: Vector3
	var b: Vector3
	var c: Vector3
	if fx + fy <= 1.0:
		a = _grid_surface_vertex(face, ix, iy)
		b = _grid_surface_vertex(face, ix + 1, iy)
		c = _grid_surface_vertex(face, ix, iy + 1)
	else:
		a = _grid_surface_vertex(face, ix + 1, iy + 1)
		b = _grid_surface_vertex(face, ix, iy + 1)
		c = _grid_surface_vertex(face, ix + 1, iy)
	var normal := (b - a).cross(c - a).normalized()
	var denominator := radial.dot(normal)
	var radius := PLAYABLE_RADIUS_METERS
	if absf(denominator) > 0.000001:
		radius = (a - PLAYABLE_CENTER).dot(normal) / denominator
	return PLAYABLE_CENTER + radial * (radius + altitude)


func surface_position_at(world_position: Vector3, altitude: float = 0.0) -> Vector3:
	return to_global(surface_position(to_local(world_position) - PLAYABLE_CENTER,
		altitude))


func altitude_at(world_position: Vector3) -> float:
	var local := to_local(world_position)
	return local.distance_to(PLAYABLE_CENTER) \
		- surface_position(local - PLAYABLE_CENTER).distance_to(PLAYABLE_CENTER)


static func surface_basis(direction: Vector3, forward: Vector3 = Vector3.FORWARD) -> Basis:
	var up := direction.normalized() if direction.length_squared() > 0.000001 \
		else Vector3.UP
	var tangent := forward - up * forward.dot(up)
	if tangent.length_squared() < 0.000001:
		tangent = Vector3.RIGHT - up * Vector3.RIGHT.dot(up)
	tangent = tangent.normalized()
	return Basis(up.cross(-tangent).normalized(), up, -tangent)


func shop_local_transform() -> Transform3D:
	var direction := Vector3(SHOP_XZ.x - LANDING_XZ.x,
		PLAYABLE_RADIUS_METERS, SHOP_XZ.y - LANDING_XZ.y).normalized()
	return Transform3D(surface_basis(direction), surface_position(direction))


static func shop_position_for_seed(seed_value: int) -> Vector3:
	# Dedicated servers need the exact interaction point without building meshes,
	# textures, lights or the NPC. Three deterministic triangle vertices suffice.
	var sampler := MoonWorld.new()
	sampler.moon_seed = seed_value
	var point := sampler.shop_local_transform().origin
	sampler.free()
	return point


func height_at(local_x: float, local_z: float) -> float:
	# Compatibility for old top-hemisphere callers. New movement uses the full
	# directional API; x/z alone cannot address the back of a sphere.
	var dx := local_x - PLAYABLE_CENTER.x
	var dz := local_z - PLAYABLE_CENTER.z
	var y := sqrt(maxf(PLAYABLE_RADIUS_METERS * PLAYABLE_RADIUS_METERS
		- dx * dx - dz * dz, 0.0))
	return surface_position(Vector3(dx, y, dz)).y


func _ensure_craters() -> void:
	if _crater_seed == moon_seed:
		return
	_crater_seed = moon_seed
	_crater_directions.clear()
	_crater_radii.clear()
	_crater_depths.clear()
	_crater_cutoffs.clear()
	for index in range(SPHERE_CRATER_COUNT):
		var hashed := _hash_u32(moon_seed + index * 68917 + 193)
		var direction := _fibonacci_direction(index, SPHERE_CRATER_COUNT)
		direction = Basis(Vector3.UP, float(moon_seed % 8191) * 0.001) * direction
		var radius := lerpf(18.0, 65.0, float(hashed & 0xffff) / 65535.0)
		# Three broad, low-slope landmark rims sit beyond the flattened arrival
		# zone. On a compact sphere ordinary shallow craters disappear below its
		# very close horizon; these actual collidable rims break that flat outline.
		if index < 3:
			var landmark_offsets := [Vector2(-150.0, -80.0), Vector2(-135.0, 100.0), Vector2(45.0, 185.0)]
			var offset: Vector2 = landmark_offsets[index]
			direction = Vector3(offset.x, PLAYABLE_RADIUS_METERS, offset.y).normalized()
			radius = 90.0
		_crater_directions.append(direction)
		_crater_radii.append(radius)
		_crater_depths.append(lerpf(2.0, 8.5,
			float((hashed >> 16) & 0xffff) / 65535.0))
		_crater_cutoffs.append(1.0 - pow(radius * (1.8 if index < 3 else 1.32)
			/ PLAYABLE_RADIUS_METERS, 2.0) * 0.5)


func _surface_relief(direction: Vector3) -> float:
	_ensure_craters()
	var point := direction * PLAYABLE_RADIUS_METERS
	# All noise uses 3D position, so longitude wrapping never changes the seed or
	# samples a different height on either side of a face boundary.
	var relief := sin(point.x * 0.010 + float(moon_seed % 31)) * 0.9
	relief += sin(point.y * 0.012 + point.z * 0.007) * 1.1
	relief += cos(point.z * 0.014 - point.x * 0.005) * 0.7
	var landmark_rim := 0.0
	for index in range(_crater_directions.size()):
		var alignment := direction.dot(_crater_directions[index])
		if alignment <= _crater_cutoffs[index]:
			continue
		var distance := sqrt(maxf(2.0 - 2.0 * alignment, 0.0)) \
			* PLAYABLE_RADIUS_METERS
		var normalized := distance / _crater_radii[index]
		if normalized < 1.0:
			var bowl := 1.0 - normalized * normalized
			relief -= bowl * bowl * _crater_depths[index]
		elif index >= 3:
			relief += sin((normalized - 1.0) / 0.32 * PI) \
				* _crater_depths[index] * 0.22
		if index < 3:
			var rim := exp(-pow((normalized - 1.03) / 0.38, 2.0))
			landmark_rim = maxf(landmark_rim,
				9.5 * rim * (1.0 - smoothstep(1.60, 1.80, normalized)))
	relief += landmark_rim
	for pad in [LANDING_XZ, SHOP_XZ]:
		var pad_direction := Vector3(pad.x - LANDING_XZ.x,
			PLAYABLE_RADIUS_METERS, pad.y - LANDING_XZ.y).normalized()
		var distance := direction.distance_to(pad_direction) * PLAYABLE_RADIUS_METERS
		if distance < 72.0:
			relief *= smoothstep(30.0, 72.0, distance)
	return relief


static func _cube_grid_point(face: int, x: int, y: int) -> Vector3i:
	var u := x * 2 - SPHERE_FACE_SEGMENTS
	var v := y * 2 - SPHERE_FACE_SEGMENTS
	match face:
		0: return Vector3i(SPHERE_FACE_SEGMENTS, v, -u)
		1: return Vector3i(-SPHERE_FACE_SEGMENTS, v, u)
		2: return Vector3i(u, SPHERE_FACE_SEGMENTS, -v)
		3: return Vector3i(u, -SPHERE_FACE_SEGMENTS, v)
		4: return Vector3i(u, v, SPHERE_FACE_SEGMENTS)
		_: return Vector3i(-u, v, -SPHERE_FACE_SEGMENTS)


static func _direction_grid(direction: Vector3) -> Vector3:
	var face: int
	var uv: Vector2
	var absolute := direction.abs()
	if absolute.x >= absolute.y and absolute.x >= absolute.z:
		face = 0 if direction.x >= 0.0 else 1
		uv = Vector2(-direction.z if face == 0 else direction.z,
			direction.y) / absolute.x
	elif absolute.y >= absolute.z:
		face = 2 if direction.y >= 0.0 else 3
		uv = Vector2(direction.x, -direction.z if face == 2 else direction.z) \
			/ absolute.y
	else:
		face = 4 if direction.z >= 0.0 else 5
		uv = Vector2(direction.x if face == 4 else -direction.x,
			direction.y) / absolute.z
	return Vector3(float(face), (uv.x + 1.0) * 0.5 * SPHERE_FACE_SEGMENTS,
		(uv.y + 1.0) * 0.5 * SPHERE_FACE_SEGMENTS)


func _grid_surface_vertex(face: int, x: int, y: int) -> Vector3:
	var key := _cube_grid_point(face, x, y)
	if _grid_vertex_indices.has(key):
		return _sphere_vertices[int(_grid_vertex_indices[key])]
	var direction := Vector3(key).normalized()
	return PLAYABLE_CENTER + direction \
		* (PLAYABLE_RADIUS_METERS + _surface_relief(direction))


## Astronomical surface sampler retained for the orbital voyage. Walking,
## collisions and gameplay placement use surface_position on the compact sphere.
func cinematic_surface_point(flat_local_position: Vector3) -> Vector3:
	var offset := Vector2(flat_local_position.x - LANDING_XZ.x,
		flat_local_position.z - LANDING_XZ.y)
	var radial_squared := offset.length_squared()
	var sag := MOON_RADIUS_METERS if radial_squared \
		>= MOON_RADIUS_METERS * MOON_RADIUS_METERS \
		else MOON_RADIUS_METERS - sqrt(MOON_RADIUS_METERS \
			* MOON_RADIUS_METERS - radial_squared)
	return Vector3(flat_local_position.x,
		flat_local_position.y - sag, flat_local_position.z)


func _cinematic_surface_normal(local_position: Vector3) -> Vector3:
	var surface := cinematic_surface_point(Vector3(
		local_position.x, 0.0, local_position.z))
	var centre := Vector3(LANDING_XZ.x, -MOON_RADIUS_METERS, LANDING_XZ.y)
	return (surface - centre).normalized()


## Restores the playable sphere after the shader-only orbital presentation.
func set_cinematic_render_radius(_render_radius: float) -> void:
	# End the shader-only orbital transform before walking. Physics always uses
	# the compact sphere, so touchdown returns both visual and physical ground to
	# the same vertices in one operation.
	if _horizon_material:
		_horizon_material.set_shader_parameter("scaled_space_active", 0.0)
		_horizon_material.set_shader_parameter("scaled_cap_retraction", 0.0)
	if is_instance_valid(terrain_mesh):
		terrain_mesh.extra_cull_margin = 0.0
		terrain_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if is_instance_valid(landing_platform):
		landing_platform.extra_cull_margin = 0.0


func set_cinematic_render_transform(surface_local: Vector3,
		render_radius: float, compression: float) -> void:
	if not _horizon_material:
		return
	_horizon_material.set_shader_parameter("scaled_surface_local", surface_local)
	_horizon_material.set_shader_parameter("scaled_moon_radius", maxf(render_radius, 0.001))
	_horizon_material.set_shader_parameter("scaled_space_active", 1.0)
	_horizon_material.set_shader_parameter("scaled_cap_retraction", clampf(compression, 0.0, 1.0))
	if is_instance_valid(terrain_mesh):
		terrain_mesh.extra_cull_margin = maxf(render_radius * 2.0,
			surface_local.distance_to(Vector3(LANDING_XZ.x, 0.0, LANDING_XZ.y)))
		terrain_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if is_instance_valid(landing_platform):
		landing_platform.extra_cull_margin = maxf(render_radius * 2.0,
			surface_local.distance_to(Vector3(LANDING_XZ.x, 0.0, LANDING_XZ.y)))


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
	return Transform3D(Basis(Vector3.UP, PI),
		surface_position(Vector3.UP, ROCKET_ORIGIN_ABOVE_PAD))


func actor_landing_position() -> Vector3:
	return surface_position(Vector3(9.0, PLAYABLE_RADIUS_METERS, 0.0), 0.8)


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
	return 6 * SPHERE_FACE_SEGMENTS * SPHERE_FACE_SEGMENTS + 2


func terrain_triangle_count() -> int:
	return 12 * SPHERE_FACE_SEGMENTS * SPHERE_FACE_SEGMENTS


func _build_terrain() -> void:
	_ensure_surface_material()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	# Weld the six cube faces by integer lattice coordinates before projection.
	# Every edge belongs to exactly two triangles, including all eight corners.
	for face in range(6):
		for y in range(SPHERE_FACE_SEGMENTS + 1):
			for x in range(SPHERE_FACE_SEGMENTS + 1):
				var key := _cube_grid_point(face, x, y)
				var point := _grid_surface_vertex(face, x, y)
				_store_relief_height(face, x, y, point)
				if _grid_vertex_indices.has(key):
					continue
				_grid_vertex_indices[key] = _sphere_vertices.size()
				_sphere_vertices.append(point)
				normals.append(Vector3.ZERO)
				var mineral := 0.97 + 0.035 * sin(point.x * 0.017 + point.z * 0.011)
				colors.append(Color(mineral, mineral * 0.99, mineral * 0.96))
		for y in range(SPHERE_FACE_SEGMENTS):
			for x in range(SPHERE_FACE_SEGMENTS):
				var a: int = _grid_vertex_indices[_cube_grid_point(face, x, y)]
				var b: int = _grid_vertex_indices[_cube_grid_point(face, x + 1, y)]
				var c: int = _grid_vertex_indices[_cube_grid_point(face, x, y + 1)]
				var d: int = _grid_vertex_indices[_cube_grid_point(face, x + 1, y + 1)]
				_sphere_indices.append_array(PackedInt32Array([a, c, b, b, c, d]))
	for index in range(0, _sphere_indices.size(), 3):
		var a := _sphere_indices[index]
		var b := _sphere_indices[index + 1]
		var c := _sphere_indices[index + 2]
		# Godot's clockwise winding has the opposite sign to the usual cross.
		var normal := (_sphere_vertices[c] - _sphere_vertices[a]).cross(
			_sphere_vertices[b] - _sphere_vertices[a])
		normals[a] += normal
		normals[b] += normal
		normals[c] += normal
	for index in range(normals.size()):
		normals[index] = normals[index].normalized()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = _sphere_vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = _sphere_indices
	_publish_relief_texture()
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	terrain_mesh = MeshInstance3D.new()
	terrain_mesh.name = "ClosedLunarSphere"
	terrain_mesh.mesh = mesh
	terrain_mesh.material_override = _horizon_material
	# Receive actor/rock/kiosk shadows without projecting this entire curved
	# receiver back onto itself; spherical self-shadow acne reads as contour rings.
	terrain_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# A 150 km cull margin inflated local shadow bounds and lost contact detail.
	# The actual mesh bounds are sufficient whenever gameplay owns the surface.
	terrain_mesh.extra_cull_margin = 0.0
	add_child(terrain_mesh)
	# Diagnostic aliases reference this one closed surface rather than an
	# overlapping cap, tile and decorative horizon.
	lunar_far_surface_fill = terrain_mesh
	lunar_visual_horizon = terrain_mesh
	terrain_body = StaticBody3D.new()
	terrain_body.name = "ClosedLunarGround"
	terrain_body.collision_layer = 1
	terrain_body.collision_mask = 1
	var collision := CollisionShape3D.new()
	collision.name = "ExactSphericalTerrainCollision"
	collision.shape = mesh.create_trimesh_shape()
	terrain_body.add_child(collision)
	add_child(terrain_body)


func _build_landing_platform() -> void:
	# A rigid four-legged vehicle needs a common contact plane. The surrounding
	# terrain remains a sphere; this shallow foundation buries its skirt below
	# the native collision facets while its top meets the authored landing pose.
	var landing_surface := surface_position(Vector3.UP)
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = LANDING_PLATFORM_RADIUS
	cylinder.bottom_radius = LANDING_PLATFORM_RADIUS
	cylinder.height = LANDING_PLATFORM_THICKNESS
	cylinder.radial_segments = 64
	var arrays := cylinder.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var colors := PackedColorArray()
	var offset := landing_surface - Vector3.UP * LANDING_PLATFORM_THICKNESS * 0.5
	for index in range(vertices.size()):
		vertices[index] += offset
		colors.append(Color(1.12, 1.13, 1.12) if normals[index].y > 0.5
			else Color(0.78, 0.80, 0.82))
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_COLOR] = colors
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	landing_platform = MeshInstance3D.new()
	landing_platform.name = "LunarLandingPlatform"
	landing_platform.mesh = mesh
	# The shared shader expects Moon-local vertices, including the planet centre.
	# Baking that offset above keeps the platform attached during every scaled
	# arrival/departure frame instead of leaving an early floating slab in space.
	landing_platform.material_override = _horizon_material
	landing_platform.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(landing_platform)
	landing_platform_body = StaticBody3D.new()
	landing_platform_body.name = "LunarLandingPlatformContact"
	landing_platform_body.collision_layer = 1
	landing_platform_body.collision_mask = 1
	var collision := CollisionShape3D.new()
	collision.shape = mesh.create_trimesh_shape()
	landing_platform_body.add_child(collision)
	add_child(landing_platform_body)


func _build_rock_field() -> void:
	# One draw scatters ejecta over the entire sphere. The close landing field is
	# denser; every large visible boulder has a matching convex contact shape.
	_ensure_lunar_rock_resources()
	var rocks := MultiMeshInstance3D.new()
	rocks.name = "LunarEjectaBoulders"
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.use_colors = true
	multimesh.mesh = _lunar_rock_mesh
	multimesh.instance_count = LUNAR_ROCK_COUNT
	var reserved_directions: Array[Vector3] = [Vector3.UP,
		Vector3(SHOP_XZ.x - LANDING_XZ.x, PLAYABLE_RADIUS_METERS,
			SHOP_XZ.y - LANDING_XZ.y).normalized()]
	var reserved_radii: Array[float] = [25.0, 25.0]
	for facility in [&"farm", &"aging", &"observatory", &"relay", &"crystal_garden"]:
		reserved_directions.append(MoonColony.facility_direction(facility))
		reserved_radii.append(18.0 if facility == &"farm" else (8.0 if facility == &"aging" else 12.0))
	for plot_id in range(MoonColony.PLOT_COUNT):
		reserved_directions.append(MoonColony.plot_direction(plot_id))
		reserved_radii.append(6.0)
	for index in range(LUNAR_ROCK_COUNT):
		var hx := _hash_u32(moon_seed + index * 2719 + 43)
		var hz := _hash_u32(moon_seed + index * 4517 + 101)
		var hs := _hash_u32(moon_seed + index * 6991 + 229)
		var direction := _fibonacci_direction(index, LUNAR_ROCK_COUNT)
		if index < LUNAR_ROCK_COUNT / 2:
			var x := lerpf(-360.0, 360.0, float(hx & 0xffff) / 65535.0)
			var z := lerpf(-360.0, 360.0, float(hz & 0xffff) / 65535.0)
			direction = Vector3(x, PLAYABLE_RADIUS_METERS, z).normalized()
		for reserved_id in range(reserved_directions.size()):
			# Include the maximum boulder radius so an edge rock cannot reach
			# into a plot, terminal, landing pad or the farmer's service lane.
			var exclusion := (reserved_radii[reserved_id] + 2.6) / PLAYABLE_RADIUS_METERS
			if direction.distance_squared_to(reserved_directions[reserved_id]) < exclusion * exclusion:
				direction = -direction
				break
		var size := lerpf(0.35, 2.6, pow(float(hs & 0xff) / 255.0, 2.2))
		var yaw := float((hs >> 8) & 0xffff) / 65535.0 * TAU
		var squash := lerpf(0.42, 0.76, float((hs >> 24) & 0xff) / 255.0)
		var rotation_basis := surface_basis(direction) * Basis(Vector3.UP, yaw)
		var basis := rotation_basis.scaled_local(Vector3(size, size * squash, size * 0.78))
		# Partly embed ejecta so even the sloping side of a faceted rock meets the
		# exact triangle beneath it rather than balancing above a radial sample.
		var origin := surface_position(direction, size * squash * 0.12)
		multimesh.set_instance_transform(index, Transform3D(basis, origin))
		var tint := lerpf(0.58, 0.84, float((hs >> 16) & 0xff) / 255.0)
		multimesh.set_instance_color(index, Color(tint, tint * 0.98, tint * 0.93))
		if size >= 1.0:
			var collision := CollisionShape3D.new()
			var shape := ConvexPolygonShape3D.new()
			# Each convex shape owns its scaled copy. The shared source remains
			# unchanged for every rock and every later Moon instance.
			var rock_vertices := _lunar_rock_vertices.duplicate()
			for vertex in range(rock_vertices.size()):
				rock_vertices[vertex] *= Vector3(size, size * squash, size * 0.78)
			shape.points = rock_vertices
			collision.shape = shape
			collision.transform = Transform3D(rotation_basis, origin)
			terrain_body.add_child(collision)
	rocks.multimesh = multimesh
	rocks.material_override = _lunar_rock_material
	rocks.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	add_child(rocks)


func _build_gravity_volume() -> void:
	gravity_area = Area3D.new()
	gravity_area.name = "SphericalLunarVacuumAndGravity"
	gravity_area.position = PLAYABLE_CENTER
	gravity_area.gravity_space_override = Area3D.SPACE_OVERRIDE_REPLACE
	gravity_area.gravity_point = true
	gravity_area.gravity_point_center = Vector3.ZERO
	# Zero unit distance keeps lunar acceleration constant throughout gameplay.
	gravity_area.gravity_point_unit_distance = 0.0
	gravity_area.gravity = LUNAR_GRAVITY
	gravity_area.monitoring = true
	gravity_area.collision_layer = 0
	gravity_area.collision_mask = 1 | 2
	var shape_node := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = PLAYABLE_RADIUS_METERS + VACUUM_HEIGHT
	shape_node.shape = sphere
	gravity_area.add_child(shape_node)
	gravity_area.body_entered.connect(_on_body_entered)
	gravity_area.body_exited.connect(_on_body_exited)
	add_child(gravity_area)


func _build_lighting() -> void:
	var sunlight := DirectionalLight3D.new()
	sunlight.name = "HarshLunarSunlight"
	sunlight.light_color = Color(1.0, 0.985, 0.97)
	sunlight.light_energy = 1.15
	# One short-range lunar shadow pass anchors boots, kiosk supports, rocks and
	# the lander. The parent realm toggle retires Earth's directional lights.
	sunlight.shadow_enabled = true
	sunlight.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	sunlight.directional_shadow_max_distance = 60.0
	sunlight.light_angular_distance = 0.0
	sunlight.shadow_blur = 0.0
	sunlight.shadow_bias = 0.004
	sunlight.shadow_normal_bias = 0.04
	sunlight.rotation_degrees = Vector3(-52.0, -28.0, 0.0)
	add_child(sunlight)
	_sunlight = sunlight
	_lunar_sun_direction = sunlight.basis.z.normalized()
	var fill := DirectionalLight3D.new()
	fill.name = "SoftLunarSuitFill"
	fill.light_color = Color(0.78, 0.86, 1.0)
	fill.light_energy = 0.09
	fill.shadow_enabled = false
	fill.rotation_degrees = Vector3(-28.0, 150.0, 0.0)
	add_child(fill)
	# The camera override gives an airless background in every direction, even
	# when a far-plane clips the decorative star shell. Earth keeps its own sky.
	lunar_environment = Environment.new()
	lunar_environment.background_mode = Environment.BG_COLOR
	lunar_environment.background_color = Color(0.0015, 0.0020, 0.004)
	lunar_environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	lunar_environment.ambient_light_color = Color(0.61, 0.65, 0.72)
	lunar_environment.ambient_light_energy = 0.24
	lunar_environment.ssao_enabled = true
	lunar_environment.ssao_radius = 0.7
	lunar_environment.ssao_intensity = 1.0
	lunar_environment.ssao_power = 1.15
	lunar_environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC


func _build_lunar_sky() -> void:
	# A camera sky has no parallax, clipping shell or seeded counterfeit stars.
	# Real constellation figures and the photographic sky use one Galactic frame.
	lunar_sky = LunarSky.new()
	var sky := Sky.new()
	sky.sky_material = lunar_sky.get_material()
	sky.process_mode = Sky.PROCESS_MODE_INCREMENTAL
	sky.radiance_size = Sky.RADIANCE_SIZE_32
	lunar_environment.background_mode = Environment.BG_SKY
	lunar_environment.sky = sky
	set_lunar_sun_direction(_lunar_sun_direction)


func set_lunar_sun_direction(direction: Vector3) -> void:
	if direction.length_squared() < 0.0001:
		return
	_lunar_sun_direction = direction.normalized()
	if is_instance_valid(_sunlight):
		var up := Vector3.UP if absf(_lunar_sun_direction.y) < 0.98 else Vector3.RIGHT
		# DirectionalLight emits along -Z: its +Z points toward the visible Sun.
		_sunlight.basis = Basis.looking_at(-_lunar_sun_direction, up)
	if _horizon_material:
		_horizon_material.set_shader_parameter("lunar_sun_direction", _lunar_sun_direction)
	if lunar_sky:
		lunar_sky.set_sun_direction(_lunar_sun_direction)


func lunar_sun_direction() -> Vector3:
	return _lunar_sun_direction


func set_observation_mode(enabled: bool) -> void:
	if lunar_sky:
		lunar_sky.set_observation_mode(enabled)


static func _fibonacci_direction(index: int, count: int) -> Vector3:
	var y := 1.0 - (float(index) + 0.5) * 2.0 / float(count)
	var radial := sqrt(maxf(0.0, 1.0 - y * y))
	var angle := float(index) * 2.399963229728653
	return Vector3(cos(angle) * radial, y, sin(angle) * radial)


static func _ensure_lunar_rock_resources() -> void:
	if _lunar_rock_material:
		return
	_lunar_rock_mesh = SphereMesh.new()
	_lunar_rock_mesh.radius = 0.5
	_lunar_rock_mesh.height = 1.0
	_lunar_rock_mesh.radial_segments = 8
	_lunar_rock_mesh.rings = 4
	# PrimitiveMesh array access can synchronize with the renderer. Read this
	# immutable mesh once, not separately for every large boulder collider.
	_lunar_rock_vertices = _lunar_rock_mesh.get_mesh_arrays()[Mesh.ARRAY_VERTEX]
	_lunar_rock_material = StandardMaterial3D.new()
	_lunar_rock_material.albedo_color = Color(0.43, 0.42, 0.40)
	_lunar_rock_material.roughness = 1.0
	_lunar_rock_material.vertex_color_use_as_albedo = true
	_lunar_rock_material.disable_fog = true


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


func _ensure_surface_material() -> void:
	_relief_images.clear()
	for face in range(6):
		_relief_images.append(Image.create_empty(SPHERE_FACE_SEGMENTS+1, SPHERE_FACE_SEGMENTS+1, false, Image.FORMAT_RF))
	if not _surface_shader:
		_surface_shader = Shader.new()
		_surface_shader.code = LUNAR_CAP_SHADER
	# The geometry constants feed shader uniforms so surface projection, gravity,
	# collision and rendering cannot silently disagree after a radius change.
	_horizon_material = ShaderMaterial.new()
	_horizon_material.shader = _surface_shader
	_horizon_material.set_shader_parameter("playable_center", PLAYABLE_CENTER)
	_horizon_material.set_shader_parameter("playable_radius", PLAYABLE_RADIUS_METERS)
	_horizon_material.set_shader_parameter("scaled_moon_radius", PLAYABLE_RADIUS_METERS)
	_horizon_material.set_shader_parameter("scaled_surface_local", Vector3(LANDING_XZ.x, 0.0, LANDING_XZ.y))
	_horizon_material.set_shader_parameter("lunar_atlas", SpaceVoyageVisuals.shared_moon_texture())
	_horizon_material.set_shader_parameter("lunar_microdetail", LUNAR_MICRODETAIL)


func _store_relief_height(face: int, x: int, y: int, point: Vector3) -> void:
	_relief_images[face].set_pixel(x,y,Color((point-PLAYABLE_CENTER).length(),0,0,1))


func _publish_relief_texture() -> void:
	if _relief_texture: return
	_relief_texture=Texture2DArray.new()
	_relief_texture.create_from_images(_relief_images)
	_horizon_material.set_shader_parameter("terrain_radii",_relief_texture)
	_horizon_material.set_shader_parameter("terrain_grid_segments",float(SPHERE_FACE_SEGMENTS))


func terrain_sun_visibility(point: Vector3, sunlight: Vector3) -> float:
	# CPU mirror for collision/lighting regression probes. No invented crater map.
	var origin := point-PLAYABLE_CENTER
	var sun := sunlight.normalized()
	var normal := origin.normalized()
	var elevation := origin.normalized().dot(sun)
	if elevation<=-0.025: return 0.0
	if elevation>0.55: return 1.0
	var visibility := 1.0
	for step in range(10):
		var distance_along := 2.0*pow(1.62,float(step))
		var ray := origin+normal*0.32+sun*distance_along
		var grid := _direction_grid(ray.normalized())
		var x := mini(int(grid.y),SPHERE_FACE_SEGMENTS-1)
		var y := mini(int(grid.z),SPHERE_FACE_SEGMENTS-1)
		var fx := grid.y-x
		var fy := grid.z-y
		var a := (_grid_surface_vertex(int(grid.x),x,y)-PLAYABLE_CENTER).length()
		var b := (_grid_surface_vertex(int(grid.x),x+1,y)-PLAYABLE_CENTER).length()
		var c := (_grid_surface_vertex(int(grid.x),x,y+1)-PLAYABLE_CENTER).length()
		var d := (_grid_surface_vertex(int(grid.x),x+1,y+1)-PLAYABLE_CENTER).length()
		var radius := lerpf(lerpf(a,b,fx),lerpf(c,d,fx),fy)
		var penumbra := maxf(0.08,distance_along*0.00465)
		visibility=minf(visibility,smoothstep(-penumbra,penumbra,ray.length()-radius))
	return visibility
