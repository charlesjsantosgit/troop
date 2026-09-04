class_name FrontierSite
extends Node3D
## A local worksite frame. The Moon frame is tangent to the existing spherical
## collider; all farm/job coordinates stay local and survive realm changes.

var world: World
var moon: MoonWorld
var planet := "earth"
var local_player: MonkeyPlayer:
	get:
		return world.local_player if is_instance_valid(world) else null


func surface_height(x: float, z: float) -> float:
	if planet == "moon" and is_instance_valid(moon):
		# A radial projection changes local x/z on a tilted crater slope. Solve
		# along this site's local vertical instead, keeping the authored lane and
		# foundation coordinates fixed on the exact spherical triangle surface.
		var height := 0.0
		for iteration in range(6):
			var projected := moon.surface_position_at(to_global(Vector3(x, height, z)))
			var next_height := to_local(projected).y
			if absf(next_height - height) < 0.0005:
				return next_height
			height = next_height
		return height
	if Gen.frontier_world and x * x + z * z <= 40000.0:
		# The shared generator grades this complete disk to the same constant.
		# Worker collision probes need not repeat planetary road/biome sampling.
		return Gen.FRONTIER_TOWN_HEIGHT
	return Gen.height(x, z)


func surface_normal(x: float, z: float) -> Vector3:
	if planet == "moon" and is_instance_valid(moon):
		return (global_basis.inverse() * moon.radial_up_at(
			to_global(Vector3(x, surface_height(x, z), z)))).normalized()
	return Vector3.UP


func surface_point(x: float, z: float, clearance := 0.0) -> Vector3:
	return to_global(Vector3(x, surface_height(x, z), z)
		+ surface_normal(x, z) * clearance)
