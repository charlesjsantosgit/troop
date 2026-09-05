class_name CartographySource
extends RefCounted
## Private, unparented samplers. The map worker never reads or mutates the live
## Gen caches, scene tree, collision objects or rendering resources.
const Generator = preload("res://scripts/gen.gd")
const MACRO_CACHE_LIMIT := 32768
const Plan = preload("res://scripts/city_plan.gd")

class CachedMoon extends MoonWorld:
	# Keep the real collision-triangle interpolation, but retain only vertices
	# actually queried. A local preview must not wait for an entire planet bake.
	func _grid_surface_vertex(face: int, x: int, y: int) -> Vector3:
		var key := _cube_grid_point(face, x, y)
		if _grid_vertex_indices.has(key):
			return _sphere_vertices[int(_grid_vertex_indices[key])]
		var point := super._grid_surface_vertex(face, x, y)
		_grid_vertex_indices[key] = _sphere_vertices.size()
		_sphere_vertices.append(point)
		return point

var earth: Node
var moon: MoonWorld
var signature := ""
var cancelled := false

func configure(options: Dictionary) -> void:
	var next := "%d:%d:%s:%s" % [options.seed, options.moon_seed,
		options.frontier, options.debug]
	if next == signature: return
	if is_instance_valid(earth): earth.free()
	if is_instance_valid(moon): moon.free()
	earth = Generator.new()
	earth.frontier_world = options.frontier
	earth.debug_world = options.debug
	earth.setup(int(options.seed))
	moon = CachedMoon.new()
	moon.moon_seed = int(options.moon_seed)
	signature = next

static func lunar_direction(coordinate: Vector2) -> Vector3:
	var angle := coordinate / MoonWorld.PLAYABLE_RADIUS_METERS
	return Vector3(sin(angle.x) * cos(angle.y), cos(angle.x) * cos(angle.y),
		sin(angle.y)).normalized()

static func lunar_coordinate(direction: Vector3) -> Vector2:
	var d := direction.normalized()
	return Vector2(atan2(d.x, d.y), asin(clampf(d.z, -1.0, 1.0))) \
		* MoonWorld.PLAYABLE_RADIUS_METERS

func sample(body: int, coordinate: Vector2) -> Dictionary:
	if body == 1:
		var direction := lunar_direction(coordinate)
		var height := moon.surface_position(direction).distance_to(MoonWorld.PLAYABLE_CENTER) \
			- MoonWorld.PLAYABLE_RADIUS_METERS
		return {"elevation": height, "water": false,
			"color": Color("b9b2a1").lerp(Color("626c85"), clampf((2.0 - height) / 10.0, 0, 1))}
	var point: Vector2 = earth.canonical_planet_xz(coordinate)
	# Inside the city the shared terrain contract is analytic and flat except
	# its real pond basin. This is the same grade used by physical chunks.
	if earth.frontier_world and Plan.contains(point):
		var depth := Plan.pond_depth(point)
		var wet := depth > Plan.GROUND_Y - Plan.POND_SURFACE_Y
		return {"elevation": Plan.GROUND_Y - depth, "water": wet,
			"color": Color("579aa8") if wet else Color("bac3bd")}
	if earth._planet._macro_lattice_cache.size() >= MACRO_CACHE_LIMIT:
		earth._planet._macro_lattice_cache.clear()
	var macro: Dictionary = earth.planet_terrain_sample(point.x, point.y)
	var height: float = earth.planet_height_from_sample(macro)
	var water: bool = height < earth.WATER_Y
	# Continuous climate/elevation fields avoid aliasing small ground-biome
	# patches into false pixel-sized geography at global scale.
	var moisture := float(macro.get("moisture", .5))
	var temperature := float(macro.get("temperature", .5))
	var color := Color("d4b984").lerp(Color("56866b"), smoothstep(.18, .72, moisture))
	color = color.lerp(Color("a5b09c"), 1.0 - smoothstep(.13, .34, temperature))
	color = color.lerp(Color("e2e9e8"), 1.0 - smoothstep(.06, .16, temperature))

	if water:
		color = Color("6eacb8").lerp(Color("254f78"), clampf((earth.WATER_Y - height) / 240.0, 0, 1))
	else:
		color = color.lerp(Color("d1cbc0"), smoothstep(1800.0, 4200.0, height) * .65)

	if earth._planet._macro_lattice_cache.size() > MACRO_CACHE_LIMIT:
		earth._planet._macro_lattice_cache.clear()
	return {"elevation": height, "water": water, "color": color}

func bake(job: Dictionary) -> Dictionary:
	configure(job.options)
	var resolution: Vector2i = job.resolution
	var image := Image.create(resolution.x, resolution.y, false, Image.FORMAT_RGBA8)
	var heights := PackedFloat32Array()
	heights.resize(resolution.x * resolution.y)
	var colors := PackedColorArray()
	colors.resize(heights.size())
	var samples := 0
	for y in range(resolution.y):
		if cancelled: return {}
		for x in range(resolution.x):
			var uv := Vector2(x, y) / Vector2(resolution - Vector2i.ONE)
			var p: Vector2 = job.origin + uv * job.extent
			var value := sample(int(job.body), p)
			var index := y * resolution.x + x
			heights[index] = value.elevation
			colors[index] = value.color
			samples += 1
	var step: Vector2 = job.extent / Vector2(resolution - Vector2i.ONE)
	for y in range(resolution.y):
		if cancelled: return {}
		for x in range(resolution.x):
			var index := y * resolution.x + x
			var dx := (heights[y * resolution.x + mini(x + 1, resolution.x - 1)] \
				- heights[y * resolution.x + maxi(x - 1, 0)]) / (step.x * 2.0)
			var dz := (heights[mini(y + 1, resolution.y - 1) * resolution.x + x] \
				- heights[maxi(y - 1, 0) * resolution.x + x]) / (step.y * 2.0)
			var exaggeration := 2.0 if int(job.body) == 1 else 1.0
			var shade := clampf(Vector3(-dx * exaggeration, 1, -dz * exaggeration).normalized().dot(Vector3(-.45, .8, -.35).normalized()), .2, 1.0)
			image.set_pixel(x, y, colors[index] * Color(.76 + shade * .28, .76 + shade * .28, .76 + shade * .28, 1))
	image.generate_mipmaps()
	return {"image": image, "samples": samples, "job": job,
		"macro_cache_entries": earth._planet._macro_lattice_cache.size(),
		"lunar_vertices": moon._sphere_vertices.size()}

func dispose() -> void:
	if is_instance_valid(earth): earth.free()
	if is_instance_valid(moon): moon.free()
