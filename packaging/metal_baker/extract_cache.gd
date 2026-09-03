extends SceneTree
## Extract only Godot's exported Metal groups, never host-specific user caches.

var _count := 0
var _output := ""
var _failed := false

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 2 or not ProjectSettings.load_resource_pack(args[0]):
		quit(1)
		return
	_output = args[1]
	if not _output.is_absolute_path() or DirAccess.dir_exists_absolute(_output):
		push_error("Extraction needs a new absolute output directory")
		quit(1)
		return
	_copy("res://.godot/shader_cache")
	print("EXTRACTED_METAL_GROUPS ", _count)
	quit(0 if _count > 0 and not _failed else 1)

func _copy(path: String) -> void:
	var directory := DirAccess.open(path)
	if directory == null:
		_failed = true
		return
	for name in directory.get_directories():
		_copy(path.path_join(name))
	for name in directory.get_files():
		if not name.ends_with(".metal.cache"):
			continue
		var source := path.path_join(name)
		var destination := _output.path_join(source.trim_prefix("res://.godot/shader_cache/"))
		if DirAccess.make_dir_recursive_absolute(destination.get_base_dir()) != OK:
			_failed = true
			return
		var file := FileAccess.open(destination, FileAccess.WRITE)
		if file == null:
			_failed = true
			return
		var bytes := FileAccess.get_file_as_bytes(source)
		file.store_buffer(bytes)
		_failed = _failed or bytes.is_empty() or file.get_error() != OK
		_count += 1
