extends SceneTree
## godot --headless --path . --script res://tests/sharedtexturecachetest.gd
## Loading all four consumer scripts must not load their gameplay textures.
## This checks resource identity/lazy loading, not native graphics latency.

var passed := 0
var total := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	# --script is compiled before autoload globals exist. Load consumers after
	# startup so their normal Gen/Net/Sfx dependencies are available.
	var visual_library: Script = load("res://scripts/visuals.gd")
	var voyage_library: Script = load("res://scripts/space_voyage_visuals.gd")
	var map_library: Script = load("res://scripts/world_map.gd")
	var moon_library: Script = load("res://scripts/moon_world.gd")
	var initially_unloaded := SharedTextureCache._textures.is_empty() \
		and SharedTextureCache._requested.is_empty()
	for path in SharedTextureCache.TEXTURE_PATHS:
		initially_unloaded = initially_unloaded and not ResourceLoader.has_cached(path)
	_check(initially_unloaded,
		"autoloads and all consumer script preloads perform no texture loading")
	_check(not SharedTextureCache.is_ready() and SharedTextureCache.poll() == OK
			and SharedTextureCache._requested.is_empty(),
		"readiness and polling never implicitly start loading")

	var detail: Texture2D = visual_library.TERRAIN_MICRODETAIL
	_check(detail != null and SharedTextureCache._textures.size() == 1,
		"direct offline access lazily loads exactly its requested texture")
	_check(detail == voyage_library.PLANET_MICRODETAIL
			and detail == map_library.SATELLITE_DETAIL_OVERLAY
			and detail == moon_library.LUNAR_MICRODETAIL,
		"all four consumers share the identical microdetail resource")
	_check(not ResourceLoader.has_cached(SharedTextureCache.EARTH_PATH)
			and not ResourceLoader.has_cached(SharedTextureCache.MOON_PATH)
			and not ResourceLoader.has_cached(SharedTextureCache.FLOOR_PATH),
		"a lazy microdetail read does not load unrelated large textures")

	_check(SharedTextureCache.request_all() == OK
			and SharedTextureCache._requested.size() == 3,
		"asynchronous requests skip the texture already held in cache")
	_check(SharedTextureCache.request_all() == OK
			and SharedTextureCache._requested.size() == 3,
		"repeated requests are idempotent while work is in flight")
	var deadline := Time.get_ticks_msec() + 20000
	while not SharedTextureCache.is_ready() \
			and SharedTextureCache.get_error() == OK \
			and Time.get_ticks_msec() < deadline:
		SharedTextureCache.poll()
		await process_frame
	_check(SharedTextureCache.is_ready() and SharedTextureCache.get_error() == OK,
		"threaded loading reaches complete readiness within its bounded deadline")
	if not SharedTextureCache.is_ready():
		_finish()
		return
	_check(SharedTextureCache._textures.size() == 4
			and SharedTextureCache.request_all() == OK
			and SharedTextureCache.poll() == OK,
		"ready cache holds exactly four textures and remains idempotent")
	_check(visual_library.EARTH_CINEMATIC_ATLAS == voyage_library.EARTH_ATLAS
			and voyage_library.EARTH_ATLAS == map_library.EARTH_ATLAS,
		"terrain, voyage, and map retain identical Earth atlas identity")
	_check(voyage_library.MOON_ATLAS == map_library.MOON_ATLAS,
		"voyage and map retain identical Moon atlas identity")
	_check(map_library.EARTH_ATLAS.get_size() == Vector2(4096, 2048)
			and map_library.MOON_ATLAS.get_size() == Vector2(4096, 2048)
			and visual_library.TERRAIN_FLOOR_ALBEDO != null,
		"original full-resolution atlases and floor texture remain available")
	_finish()


func _finish() -> void:
	print("SHAREDTEXTURECACHETEST %d/%d %s" % [passed, total,
		"PASS" if passed == total else "FAIL"])
	quit(0 if passed == total else 1)


func _check(condition: bool, label: String) -> void:
	total += 1
	passed += int(condition)
	print("  [%s] %s" % ["ok" if condition else "FAIL", label])
