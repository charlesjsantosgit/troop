class_name CityMassing
extends RefCounted
## Shared physical volumes for collisions, rendering and continuous crash sweeps.
static func sections(record: Dictionary) -> Array[Dictionary]:
	# The same masses drive detail, distant silhouettes and physical collisions.
	# All roof structures stay inside the authoritative height/parcel envelope.
	var size: Vector3 = record.size
	if size.y < 36.0:
		return [{"offset": Vector3(0.0, size.y * 0.5, 0.0), "size": size}]
	var seed := posmod(int(record.get("facade_seed",String(record.id).hash())),100000)
	var podium := minf(15.2, size.y * 0.18)
	var shoulder := size.y * (0.73 + float(seed % 3) * 0.035)
	var crown_height := clampf(size.y * 0.045, 2.8, 16.0)
	var upper_top := size.y - crown_height
	var tower_scale := 0.82 if seed % 3 == 0 else 0.88
	var upper_scale := tower_scale * (0.76 if seed % 2 == 0 else 0.91)
	var crown_scale := upper_scale * (0.55 if seed % 4 == 0 else 0.85)
	# Mid-rise street walls and broad office slabs retain continuous faces;
	# stepped Art Deco crowns belong to selected taller landmarks.
	if size.y < 100.0:
		podium = size.y * 0.28
		shoulder = size.y * 0.78
		upper_top = size.y * 0.96
		crown_height = size.y - upper_top
		tower_scale = 1.0
		upper_scale = 0.98 if seed % 3 == 0 else 1.0
		crown_scale = 0.80 if seed % 3 == 0 else 0.96
	elif seed % 3 == 1:
		tower_scale = 0.96
		upper_scale = 0.96
		crown_scale = 0.84
	return [
		{"offset": Vector3(0.0, podium * 0.5, 0.0), "size": Vector3(size.x, podium, size.z)},
		{"offset": Vector3(0.0, (podium + shoulder) * 0.5, 0.0), "size": Vector3(size.x * tower_scale, shoulder - podium, size.z * tower_scale)},
		{"offset": Vector3(0.0, (shoulder + upper_top) * 0.5, 0.0), "size": Vector3(size.x * upper_scale, upper_top - shoulder, size.z * upper_scale)},
		{"offset": Vector3(0.0, upper_top + crown_height * 0.5, 0.0), "size": Vector3(size.x * crown_scale, crown_height, size.z * crown_scale)},
	]


