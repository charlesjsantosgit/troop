@tool
extends EditorExportPlugin
## Editor-only injection, never shader baking. The release builder must run the
## structural Python verifier and inspect the resulting PCK before publishing.
## Godot 4.7 has no EditorExportPlugin abort API: add_message/push_error alone do
## not make the CLI exit nonzero. Direct editor exports are NOT a release gate.

const CACHE_ROOT := "res://packaging/metal_cache"
const PACK_ROOT := "res://.godot/shader_cache/"
const SOURCE_ROOT := "res://addons/metal_cache_export/"
const ENGINE_VERSION := "4.7.stable.official.5b4e0cb0f"
const TARGET_MIN_OS := "11.0"
const MAX_MANIFEST_BYTES := 16 * 1024 * 1024
const MAX_FILE_BYTES := 64 * 1024 * 1024
const MAX_TREE_BYTES := 512 * 1024 * 1024
const MAX_FILES := 1024
const CACHE_PATH_PATTERN := "\\A[A-Za-z][A-Za-z0-9_]{0,127}/[0-9a-f]{64}/[0-9a-f]{40}\\.metal\\.cache\\z"
const SHA256_PATTERN := "\\A[0-9a-f]{64}\\z"


func _get_name() -> String:
	return "TROOPPortableMetalCache"


func _supports_platform(_platform: EditorExportPlatform) -> bool:
	# Source-only files must also be excluded from the dedicated server.
	return true


static func wants_cache(features: PackedStringArray) -> bool:
	return (features.has("windows") or features.has("macos")) and not features.has("dedicated_server")


static func is_source_file(path: String) -> bool:
	return path.begins_with(SOURCE_ROOT) or path.begins_with(CACHE_ROOT + "/")


func _export_file(path: String, _type: String, _features: PackedStringArray) -> void:
	if is_source_file(path):
		skip()


func _export_begin(features: PackedStringArray, is_debug: bool, _path: String, _flags: int) -> void:
	var platform := get_export_platform()
	if platform == null or not wants_cache(features):
		return
	var checked := validate_cache(CACHE_ROOT, runtime_engine_version())
	if not checked.error.is_empty():
		var message := "METAL_CACHE_EXPORT FAILED: " + str(checked.error)
		# Debug exports remain usable without release artifacts. A release build
		# rejects both this sentinel and EXPORT_MESSAGE_ERROR, then checks its PCK.
		if is_debug:
			platform.add_message(EditorExportPlatform.EXPORT_MESSAGE_WARNING, "Metal cache", message)
			push_warning(message)
		else:
			platform.add_message(EditorExportPlatform.EXPORT_MESSAGE_ERROR, "Metal cache", message)
			push_error(message)
		return
	# Validate every byte before adding any file. Sorted, identical paths and
	# bytes on both platforms preserve TROOP's single universal update pack.
	for record: Dictionary in checked.files:
		add_file(PACK_ROOT + record.path, record.bytes, false)
	print("METAL_CACHE_EXPORT OK files=%d bytes=%d engine=%s target_min_os=%s" % [
		checked.files.size(), checked.total_bytes, ENGINE_VERSION, TARGET_MIN_OS])


static func runtime_engine_version() -> String:
	var version := Engine.get_version_info()
	var number := "%d.%d" % [version.major, version.minor]
	if int(version.patch) != 0:
		number += ".%d" % int(version.patch)
	return "%s.%s.%s.%s" % [number, version.status, version.build, str(version.hash).left(9)]


static func _failure(message: String) -> Dictionary:
	return {"error": message, "files": [], "total_bytes": 0}


static func _sha256(bytes: PackedByteArray) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(bytes)
	return context.finish().hex_encode()


static func _inventory(directory: String, relative: String, output: Array[String]) -> String:
	var opened := DirAccess.open(directory)
	if opened == null:
		return "missing/unreadable cache directory: " + directory
	opened.include_hidden = true
	for entry: String in opened.get_files():
		if opened.is_link(entry):
			return "cache symlink is forbidden: " + relative + entry
		output.append(relative + entry)
		if output.size() > MAX_FILES:
			return "cache inventory exceeds file limit"
	for entry: String in opened.get_directories():
		if opened.is_link(entry):
			return "cache symlink is forbidden: " + relative + entry
		# The canonical path has exactly three components. Reject arbitrary deep
		# trees before recursively visiting them, even if they contain no files.
		if relative.count("/") >= 2:
			return "unexpected nested cache directory: " + relative + entry
		var error := _inventory(directory.path_join(entry), relative + entry + "/", output)
		if not error.is_empty():
			return error
	return ""


static func validate_cache(root: String, engine_version: String) -> Dictionary:
	if engine_version != ENGINE_VERSION:
		return _failure("engine must be " + ENGINE_VERSION + "; found " + engine_version)
	var absolute_root := ProjectSettings.globalize_path(root)
	var parent := DirAccess.open(absolute_root.get_base_dir())
	if parent == null or parent.is_link(absolute_root.get_file()):
		return _failure("missing or symlinked cache root")
	var directory := DirAccess.open(root)
	if directory == null or directory.is_link("manifest.json") or directory.is_link("files"):
		return _failure("missing or symlinked manifest/cache files directory")
	var manifest_file := FileAccess.open(root.path_join("manifest.json"), FileAccess.READ)
	if manifest_file == null or manifest_file.get_length() > MAX_MANIFEST_BYTES:
		return _failure("missing, unreadable, or oversized manifest.json")
	var parser := JSON.new()
	if parser.parse(manifest_file.get_as_text()) != OK or not parser.data is Dictionary:
		return _failure("invalid manifest JSON")
	var manifest: Dictionary = parser.data
	var schema: Variant = manifest.get("schema")
	if not (schema is int or schema is float) or schema != 1:
		return _failure("manifest schema mismatch")
	if not manifest.get("engine_version") is String or manifest.engine_version != ENGINE_VERSION:
		return _failure("manifest schema/engine mismatch")
	if not manifest.get("target_min_os") is String or manifest.target_min_os != TARGET_MIN_OS:
		return _failure("manifest target_min_os must be " + TARGET_MIN_OS)
	var hex_pattern := RegEx.create_from_string(SHA256_PATTERN)
	if not manifest.get("settings_sha256") is String or hex_pattern.search(manifest.settings_sha256) == null:
		return _failure("invalid regeneration settings SHA-256")
	var records: Variant = manifest.get("files")
	if not records is Array or records.is_empty() or records.size() > MAX_FILES:
		return _failure("empty or invalid manifest inventory")
	var paths: Array[String] = []
	var path_pattern := RegEx.create_from_string(CACHE_PATH_PATTERN)
	var previous := ""
	var total := 0
	for record: Variant in records:
		if not record is Dictionary or record.size() != 3:
			return _failure("invalid manifest record")
		var path: Variant = record.get("path")
		if not path is String or path_pattern.search(path) == null or path <= previous:
			return _failure("unsafe, unsorted, or duplicate cache path")
		if not record.get("sha256") is String or hex_pattern.search(record.sha256) == null:
			return _failure("invalid cache SHA-256: " + path)
		var size: Variant = record.get("size")
		if not (size is int or size is float) or size != int(size) or size < 16 or size > MAX_FILE_BYTES:
			return _failure("invalid cache size: " + path)
		total += int(size)
		if total > MAX_TREE_BYTES:
			return _failure("cache tree exceeds byte limit")
		paths.append(path)
		previous = path
	var actual: Array[String] = []
	var inventory_error := _inventory(root.path_join("files"), "", actual)
	if not inventory_error.is_empty():
		return _failure(inventory_error)
	actual.sort()
	if actual != paths:
		return _failure("manifest and cache filesystem inventories differ")
	var payload: Array[Dictionary] = []
	for record: Dictionary in records:
		var source := FileAccess.open(root.path_join("files").path_join(record.path), FileAccess.READ)
		if source == null or source.get_length() != int(record.size):
			return _failure("missing or wrong-size cache: " + str(record.path))
		var bytes := source.get_buffer(int(record.size))
		if bytes.size() != int(record.size) or _sha256(bytes) != record.sha256:
			return _failure("cache SHA-256 mismatch: " + str(record.path))
		payload.append({"path": record.path, "bytes": bytes})
	return {"error": "", "files": payload, "total_bytes": total}
