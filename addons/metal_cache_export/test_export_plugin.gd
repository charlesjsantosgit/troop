extends SceneTree
## Run only in the disposable project created by run_tests.py. These byte-level
## plugin fixtures are not baked shaders; structural validation belongs to the
## independent packaging verifier, and no fixture is ever rendered or shipped.

const CacheExport = preload("res://addons/metal_cache_export/export_plugin.gd")
var _passed := 0
var _failed := 0
var _counter := 0
var _root := ""


func _init() -> void:
	_root = OS.get_environment("TROOP_METAL_EXPORT_TEST_ROOT")
	if _root.is_empty() or not _root.is_absolute_path():
		push_error("test requires an explicit disposable fixture root")
		quit(1)
		return
	_check(CacheExport.runtime_engine_version() == CacheExport.ENGINE_VERSION, "actual engine version pin")
	_check(CacheExport.wants_cache(["windows"]), "Windows injection")
	_check(CacheExport.wants_cache(["macos"]), "macOS injection")
	_check(not CacheExport.wants_cache(["linux"]), "Linux exclusion")
	_check(not CacheExport.wants_cache(["macos", "dedicated_server"]), "dedicated exclusion")
	_check(CacheExport.is_source_file("res://addons/metal_cache_export/plugin.gd"), "plugin source excluded")
	_check(CacheExport.is_source_file("res://packaging/metal_cache/manifest.json"), "cache source excluded")
	_check(not CacheExport.is_source_file("res://scripts/main.gd"), "game source retained")
	var root := _fixture()
	var valid := CacheExport.validate_cache(root, CacheExport.ENGINE_VERSION)
	_check(valid.error.is_empty() and valid.files.size() == 2 and valid.total_bytes == 32, "valid cache")
	_check(valid.files[0].path < valid.files[1].path, "canonical injection ordering")
	_check(valid.files[0].bytes == _bytes(0), "exact cache bytes retained")
	_rejected(root, "4.7.stable.official.000000000", "wrong engine")
	_rejected(_root.path_join("absent"), CacheExport.ENGINE_VERSION, "missing input")
	for field in ["schema", "engine_version", "settings_sha256", "target_min_os", "files"]:
		root = _fixture()
		var manifest := _manifest(root)
		manifest.erase(field)
		_write_manifest(root, manifest)
		_rejected(root, CacheExport.ENGINE_VERSION, "missing " + field)
	for field in ["schema", "engine_version", "settings_sha256", "target_min_os"]:
		root = _fixture()
		var manifest := _manifest(root)
		manifest[field] = "wrong"
		_write_manifest(root, manifest)
		_rejected(root, CacheExport.ENGINE_VERSION, "wrong " + field)
	for field in ["engine_version", "settings_sha256", "target_min_os", "files"]:
		root = _fixture()
		var manifest := _manifest(root)
		manifest[field] = 7
		_write_manifest(root, manifest)
		_rejected(root, CacheExport.ENGINE_VERSION, "wrong type " + field)
	for mode in ["empty", "duplicate", "unsorted", "traversal", "size", "hash", "extra_field"]:
		root = _fixture()
		var manifest := _manifest(root)
		match mode:
			"empty": manifest.files = []
			"duplicate": manifest.files.append(manifest.files[0])
			"unsorted": manifest.files.reverse()
			"traversal": manifest.files[0].path = "../escape.metal.cache"
			"size": manifest.files[0].size = 16.5
			"hash": manifest.files[0].sha256 = "0".repeat(64)
			"extra_field": manifest.files[0].extra = true
		_write_manifest(root, manifest)
		_rejected(root, CacheExport.ENGINE_VERSION, "reject " + mode)
	root = _fixture()
	_write(root.path_join("files/extra.cache"), _bytes(0))
	_rejected(root, CacheExport.ENGINE_VERSION, "extra filesystem file")
	root = _fixture()
	_write(root.path_join("files/.hidden"), _bytes(0))
	_rejected(root, CacheExport.ENGINE_VERSION, "extra hidden file")
	root = _fixture()
	var newline_manifest := _manifest(root)
	newline_manifest.files[0].path += "\n"
	_write_manifest(root, newline_manifest)
	_rejected(root, CacheExport.ENGINE_VERSION, "noncanonical path newline")
	root = _fixture()
	var first_path := root.path_join("files").path_join(_manifest(root).files[0].path)
	DirAccess.remove_absolute(first_path)
	_rejected(root, CacheExport.ENGINE_VERSION, "missing cache file")
	root = _fixture()
	first_path = root.path_join("files").path_join(_manifest(root).files[0].path)
	_write(first_path, _bytes(1))
	_rejected(root, CacheExport.ENGINE_VERSION, "changed same-size bytes")
	root = _fixture()
	first_path = root.path_join("files").path_join(_manifest(root).files[0].path)
	_write(first_path, PackedByteArray([1]))
	_rejected(root, CacheExport.ENGINE_VERSION, "truncated cache bytes")
	root = _fixture()
	DirAccess.make_dir_recursive_absolute(root.path_join("files/a/b/c"))
	_rejected(root, CacheExport.ENGINE_VERSION, "bounded directory depth")
	root = _fixture()
	var directory := DirAccess.open(root)
	var manifest_path := root.path_join("manifest.json")
	directory.rename("manifest.json", "original.json")
	_check(directory.create_link(root.path_join("original.json"), manifest_path) == OK, "create symlink fixture")
	_rejected(root, CacheExport.ENGINE_VERSION, "manifest symlink")
	root = _fixture()
	directory = DirAccess.open(root)
	first_path = root.path_join("files").path_join(_manifest(root).files[0].path)
	DirAccess.remove_absolute(first_path)
	_check(directory.create_link(root.path_join("manifest.json"), first_path) == OK, "create file symlink fixture")
	_rejected(root, CacheExport.ENGINE_VERSION, "cache file symlink")
	print("METALCACHEEXPORTTEST %d/%d %s" % [_passed, _passed + _failed, "PASS" if _failed == 0 else "FAIL"])
	quit(0 if _failed == 0 else 1)


func _check(passed: bool, label: String) -> void:
	if passed:
		_passed += 1
	else:
		_failed += 1
		printerr("METALCACHEEXPORTTEST FAILED " + label)


func _rejected(root: String, engine: String, label: String) -> void:
	var result := CacheExport.validate_cache(root, engine)
	_check(not result.error.is_empty() and result.files.is_empty(), label)


func _bytes(index: int) -> PackedByteArray:
	return ("GDSC" + str(index).repeat(12)).to_utf8_buffer()


func _fixture() -> String:
	_counter += 1
	var root := _root.path_join("case_%d" % _counter)
	var records: Array[Dictionary] = []
	for index in 2:
		var relative := "Shader%d/%s/%s.metal.cache" % [index, "a".repeat(64), "b".repeat(40)]
		var bytes := _bytes(index)
		_write(root.path_join("files").path_join(relative), bytes)
		records.append({"path": relative, "size": bytes.size(), "sha256": CacheExport._sha256(bytes)})
	_write_manifest(root, {"schema": 1, "engine_version": CacheExport.ENGINE_VERSION,
		"target_min_os": "11.0", "settings_sha256": "c".repeat(64), "files": records})
	return root


func _manifest(root: String) -> Dictionary:
	return JSON.parse_string(FileAccess.get_file_as_string(root.path_join("manifest.json")))


func _write_manifest(root: String, manifest: Dictionary) -> void:
	_write(root.path_join("manifest.json"), JSON.stringify(manifest).to_utf8_buffer())


func _write(path: String, bytes: PackedByteArray) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var opened := FileAccess.open(path, FileAccess.WRITE)
	opened.store_buffer(bytes)
