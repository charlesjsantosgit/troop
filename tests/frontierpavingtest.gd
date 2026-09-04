extends SceneTree
## Checks exclusive authored ground coverage, including the exact spawn-plane
## regression, against the triangles actually submitted to the renderer.
var passed := 0
var total := 0

class Site extends Node3D:
	var local_player: Node3D
	var lunar := false
	func surface_height(x: float,z: float) -> float:
		return sqrt(450.0*450.0-x*x-z*z)-450.0 if lunar else 3.25
	func surface_normal(x: float,z: float) -> Vector3:
		return Vector3(x,surface_height(x,z)+450.0,z).normalized() if lunar else Vector3.UP

func _initialize() -> void:
	call_deferred("_run")

func check(value: bool,label: String) -> void:
	total += 1
	if value: passed += 1
	print("PAVING %s %s" % ["PASS" if value else "FAIL",label])

func _run() -> void:
	var paving = load("res://scripts/frontier_paving.gd")
	var outer := PackedVector2Array([Vector2(-10,-10),Vector2(10,-10),Vector2(10,10),Vector2(-10,10)])
	var hole := PackedVector2Array([Vector2(-5,-5),Vector2(5,-5),Vector2(5,5),Vector2(-5,5)])
	var remainder: Array = paving.subtract(outer,hole)
	var area := 0.0
	for polygon: PackedVector2Array in remainder: area += absf(paving.area(polygon))
	check(absf(area-300.0)<0.00001,"an enclosed pad is removed without refilling its hole")
	check(remainder.all(func(polygon): return not Geometry2D.is_point_in_polygon(Vector2.ZERO,polygon)),
		"the removed pad's center has no leftover paving")
	var sim = load("res://scripts/frontier_sim.gd").new()
	sim.new_game(2026)
	for realm in ["earth","moon"]:
		var host := Site.new()
		host.lunar = realm=="moon"
		root.add_child(host)
		var town = load("res://scripts/frontier_settlement.gd").new()
		town.configure(host,sim,realm,{"id":"surface_test","name":"Surface test"})
		host.add_child(town)
		var steps := 0
		var longest := 0.0
		var started := Time.get_ticks_usec()
		while not town.is_build_complete():
			var before := Time.get_ticks_usec()
			town.build_step(2.0)
			longest = maxf(longest,(Time.get_ticks_usec()-before)/1000.0)
			steps += 1
		var build_ms := (Time.get_ticks_usec()-started)/1000.0
		var rendered: Array[Dictionary] = []
		var mesh_count := 0
		var vertices_match_ground := true
		var upward_normals := true
		for child in town.get_children():
			if not child is MeshInstance3D or not str(child.name).begins_with("ExclusiveTownPaving"):
				continue
			mesh_count += 1
			var arrays: Array = child.mesh.surface_get_arrays(0)
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
			for normal in normals:
				if normal.y<=0.9 and upward_normals: print("PAVING_BAD_NORMAL ",realm," ",child.name," ",normal)
				upward_normals = upward_normals and normal.y>0.9
			var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
			for index in range(0,indices.size(),3):
				var polygon := PackedVector2Array()
				for offset in range(3):
					var vertex := vertices[indices[index+offset]]
					var lift := vertex.y-host.surface_height(vertex.x,vertex.z)
					vertices_match_ground = vertices_match_ground and lift>=0.049 and lift<=0.131
					polygon.append(Vector2(vertex.x,vertex.z))
				if absf(paving.area(polygon))>0.00001:
					rendered.append({"polygon":polygon,"color":child.material_override.albedo_color})
		var pieces: Array = town._paving.pieces
		var index := _index(rendered)
		var rng := RandomNumberGenerator.new()
		rng.seed = 71831
		var overlaps := 0
		var missing := 0
		var wrong_material := 0
		var sampled := 0
		for sample in range(6000):
			var point := Vector2(rng.randf_range(-82,160),rng.randf_range(-110,105)) if realm=="earth" \
				else Vector2(rng.randf_range(-61,40),rng.randf_range(-40,33))
			var expected: Dictionary = {}
			for request: Dictionary in town._paving.requests:
				if _strictly_inside(point,request.polygon):
					expected = request
					break
			if expected.is_empty(): continue
			sampled += 1
			var owners: Array = []
			for triangle: Dictionary in index.get(_cell(point),[]):
				if _strictly_inside(point,triangle.polygon): owners.append(triangle)
			if owners.size()>1:
				overlaps += 1
				if overlaps==1: print("PAVING_OVERLAP ",point," ",owners)
			if owners.is_empty():
				var on_edge := false
				for triangle: Dictionary in index.get(_cell(point),[]):
					for edge_index in range(3):
						on_edge = on_edge or point.distance_to(Geometry2D.get_closest_point_to_segment(point,triangle.polygon[edge_index],triangle.polygon[(edge_index+1)%3]))<0.00002
				if not on_edge: missing += 1
			if owners.size()==1 and not owners[0].color.is_equal_approx(expected.color): wrong_material += 1
		check(sampled>400 and overlaps==0,"%s submitted triangles never overlap at %d occupied samples (overlaps=%d)" % [realm,sampled,overlaps])
		check(missing==0 and wrong_material==0,"%s paving preserves coverage and surface priority (missing=%d wrong=%d)" % [realm,missing,wrong_material])
		check(vertices_match_ground,"%s paving follows its real graded or curved ground" % realm)
		check(upward_normals,"%s submitted paving normals face above the ground" % realm)
		check(mesh_count<=8 and pieces.size()<1800 and rendered.size()<24000,
			"%s clipped paving stays bounded in meshes, regions and triangles" % realm)
		if realm=="earth":
			for point in [Vector2(1.83,3.22),Vector2(-2.77,4.81),Vector2(58.35,33.24),Vector2(96.22,13.76)]:
				var owners: Array = index.get(_cell(point),[]).filter(func(triangle): return _strictly_inside(point,triangle.polygon))
				check(owners.size()==1 and owners[0].color.is_equal_approx(Color(0.28,0.31,0.29)),
					"street owns exact plaza/forecourt overlap at %s" % point)
		print("PAVING_METRICS realm=%s requests=%d regions=%d meshes=%d triangles=%d steps=%d max_step_ms=%.3f total_build_ms=%.3f" %
			[realm,town._paving.requests.size(),pieces.size(),mesh_count,rendered.size(),steps,longest,build_ms])
		if realm=="moon": _verify_lunar_clearance(rendered)
		host.free()
	await process_frame
	print("FRONTIERPAVINGTEST %d/%d %s" % [passed,total,"PASS" if passed==total else "FAIL"])
	quit(0 if passed==total else 1)

func _cell(point: Vector2) -> Vector2i:
	return Vector2i(floori(point.x/8),floori(point.y/8))

func _index(triangles: Array[Dictionary]) -> Dictionary:
	var index: Dictionary = {}
	for triangle in triangles:
		var bounds := Rect2(triangle.polygon[0],Vector2.ZERO)
		for point in triangle.polygon: bounds = bounds.expand(point)
		var first := _cell(bounds.position)
		var last := _cell(bounds.end)
		for x in range(first.x,last.x+1):
			for y in range(first.y,last.y+1):
				var cell := Vector2i(x,y)
				if not index.has(cell): index[cell] = []
				index[cell].append(triangle)
	return index

func _strictly_inside(point: Vector2,polygon: PackedVector2Array) -> bool:
	# Convex half-plane test avoids Geometry2D's boundary tolerance reporting
	# both triangles on a shared subdivision diagonal as containing one point.
	var side := 0
	for index in range(polygon.size()):
		var edge := polygon[(index+1)%polygon.size()]-polygon[index]
		if edge.length_squared()<0.00000001: continue
		var distance := edge.cross(point-polygon[index])/edge.length()
		if absf(distance)<0.00001: return false
		var current := 1 if distance>0 else -1
		if side!=0 and side!=current: return false
		side=current
	return side!=0

func _verify_lunar_clearance(triangles: Array[Dictionary]) -> void:
	var moon: Node3D = load("res://scripts/moon_world.gd").new()
	moon.begin_setup(4041969 ^ 0x4d4f4f4e)
	root.add_child(moon)
	for name: String in FrontierTownLayout.MOON_DIRECTIONS:
		var site: Node3D = load("res://scripts/frontier_site.gd").new()
		site.planet="moon"
		site.moon=moon
		root.add_child(site)
		var direction: Vector3=FrontierTownLayout.MOON_DIRECTIONS[name]
		site.transform=FrontierTownLayout.world_frame({"planet":"moon","moon_direction":[direction.x,direction.y,direction.z]},moon)
		var clearance:=INF
		var samples:=0
		for index in range(0,triangles.size(),maxi(1,triangles.size()/800)):
			var triangle: Dictionary=triangles[index]
			var center:=Vector2.ZERO
			var surface_y:=0.0
			for point: Vector2 in triangle.polygon:
				center+=point/3.0
				surface_y+=float(site.surface_height(point.x,point.y))/3.0
			# 75 mm is the lowest lunar surface dressing. Pads have 90 mm.
			clearance=minf(clearance,surface_y+0.075-float(site.surface_height(center.x,center.y)))
			samples+=1
		check(clearance>0.0,"%s actual lunar crater triangles stay beneath %d paving interior samples (minimum=%.4fm)" % [name,samples,clearance])
		site.free()
	moon.free()
