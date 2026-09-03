class_name SharedTextureCache
extends RefCounted
## Gameplay textures must not be loaded by the startup script dependency graph.
## Request after the menu has drawn, then poll between frames before entering a
## world. No initializer here reads a resource or submits graphics work.

const MICRODETAIL_PATH := "res://assets/textures/satellite_microdetail_overlay.png"
const FLOOR_PATH := "res://assets/textures/jungle_floor_albedo.png"
const EARTH_PATH := "res://assets/textures/pangaea_earth_4k.jpg"
const MOON_PATH := "res://assets/textures/lunar_surface_4k.jpg"
const TEXTURE_PATHS: Array[String] = [
	MICRODETAIL_PATH, FLOOR_PATH, EARTH_PATH, MOON_PATH,
]

static var _textures: Dictionary = {}
static var _requested: Dictionary = {}
static var _error: Error = OK


static func request_all() -> Error:
	if _error != OK:
		return _error
	for path in TEXTURE_PATHS:
		if _textures.has(path) or _requested.has(path):
			continue
		var error := ResourceLoader.load_threaded_request(path, "Texture2D")
		if error != OK:
			_error = error
			return _error
		_requested[path] = true
	return OK


## Never retrieve an unfinished request: load_threaded_get would block the
## caller until its worker completes, defeating the responsive startup gate.
static func poll() -> Error:
	if _error != OK:
		return _error
	for path in _requested:
		if _textures.has(path):
			continue
		match ResourceLoader.load_threaded_get_status(path):
			ResourceLoader.THREAD_LOAD_LOADED:
				var texture := ResourceLoader.load_threaded_get(path) as Texture2D
				if texture == null:
					_error = ERR_INVALID_DATA
					return _error
				_textures[path] = texture
			ResourceLoader.THREAD_LOAD_FAILED:
				_error = ERR_CANT_OPEN
				return _error
			ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
				_error = ERR_INVALID_PARAMETER
				return _error
	return OK


## Pure state query; the caller drives request_all/poll explicitly.
static func is_ready() -> bool:
	return _error == OK and _textures.size() == TEXTURE_PATHS.size()


static func get_error() -> Error:
	return _error


## Normal menu/world entry waits for is_ready before accessing these getters.
## The synchronous fallback preserves standalone tools and offline fixtures
## that construct a world directly, without Main's asynchronous loading gate.
static func get_texture(path: String) -> Texture2D:
	if _textures.has(path):
		return _textures[path] as Texture2D
	if path not in TEXTURE_PATHS:
		push_error("SharedTextureCache rejected an unknown texture: " + path)
		return null
	var texture := ResourceLoader.load(path, "Texture2D") as Texture2D
	if texture == null:
		_error = ERR_CANT_OPEN
		push_error("SharedTextureCache could not load: " + path)
		return null
	_textures[path] = texture
	return texture
