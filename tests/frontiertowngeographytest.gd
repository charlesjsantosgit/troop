extends SceneTree
const Layout = preload("res://scripts/frontier_town_layout.gd")
var checks := 0
var passed := 0
func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	var generator = root.get_node("Gen")
	for seed in [2026, 778899, 42]:
		generator.frontier_world = true
		generator.setup(seed)
		var flat := true
		for center: Vector2 in Layout.EARTH_ORIGINS.values():
			for x in range(-120, 121, 30):
				for z in range(-120, 121, 30):
					flat = flat and absf(generator.height(center.x+x,center.y+z)-Layout.GROUND_HEIGHT)<0.001
		_check(flat, "all three town footprints use one shared terrain surface seed=%d" % seed)
		var roads := true
		var clear := true
		var chunks := {}
		for road: Array in Layout.CONNECTING_ROADS:
			for index in range(road.size()-1):
				var a: Vector2=road[index]
				var b: Vector2=road[index+1]
				for step in range(11):
					var p := a.lerp(b,step/10.0)
					roads = roads and absf(generator.height(p.x,p.y)-Layout.GROUND_HEIGHT)<0.001 and generator.point_on_road(p.x,p.y)
					chunks[Vector2i(floori(p.x/generator.CHUNK),floori(p.y/generator.CHUNK))]=true
		for chunk: Vector2i in chunks:
			var data: Dictionary=generator.chunk_layout(chunk.x,chunk.y)
			for category in ["trees","rocks","foliage","structures"]:
				for item: Dictionary in data[category]:
					var p: Vector3=item.pos
					clear = clear and Layout.road_distance(Vector2(p.x,p.z))>Layout.ROAD_HALF_WIDTH+3.0
		_check(roads,"town connectors remain flat and classified as roads seed=%d" % seed)
		_check(clear,"generated trees rocks foliage and huts leave connector roads clear seed=%d" % seed)
	generator.frontier_world = false
	print("FRONTIERTOWNGEOGRAPHYTEST %d/%d %s" % [passed,checks,"PASS" if passed==checks else "FAIL"])
	quit(0 if passed==checks else 1)
func _check(ok: bool, label: String) -> void:
	checks+=1
	if ok: passed+=1
	print(("PASS " if ok else "FAIL ")+label)
