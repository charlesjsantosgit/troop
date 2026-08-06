extends Node
## Signed GitHub Releases updater.
##
## This must remain the first autoload. `_init()` verifies and mounts a staged
## resource pack before any other autoload or scene loads, allowing ordinary
## script/scene/content releases to update without replacing the signed native
## executable. Engine, bootstrap, native-library, and project-setting changes
## deliberately fall back to the platform installer.

signal status_changed(status: String, detail: String)
signal update_available(version: String, requires_installer: bool, notes: String)
signal download_progress(version: String, downloaded_bytes: int, total_bytes: int)
signal update_staged(version: String)
signal installer_ready(version: String, path: String)
signal update_error(message: String)

const BOOTSTRAP_VERSION := 1
const MANIFEST_SCHEMA := 1
const STATE_SCHEMA := 1
const APP_ID := "com.charlessantos.troop"
const CHANNEL := "stable"
const MANIFEST_NAME := "TROOP-update.json"
const UPDATE_DIR := "user://updates"
const STATE_PATH := UPDATE_DIR + "/state.json"
const CHECK_INTERVAL_SECONDS := 6 * 60 * 60
const MANIFEST_MAX_BYTES := 128 * 1024
const CONTENT_MAX_BYTES := 128 * 1024 * 1024
const INSTALLER_MAX_BYTES := 512 * 1024 * 1024
const HASH_CHUNK_BYTES := 1024 * 1024
const BOOT_CONFIRM_SECONDS := 8.0

const UPDATE_PUBLIC_KEY_PEM := """-----BEGIN PUBLIC KEY-----
MIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAsk/W9lQVYfXiJcs151f7
qmMsuBGDu9ShDLYbXkUN/h0v0A/hKt7ccnHXYOhne4ARL3DSWtv3XG/jwjW7FxAw
1UUxKXnSqTZKkECc2ppNzmoclk0OxSYmxXzAnLRwbPa956IQTd4EYmz3xDW1s/Lg
1sfbGPzgCXHcF3emMjm1H/S4Dcc8vrrYQFkiIh6t3Im/yvTZJHFohYXfbvhB4qpG
kKYeWXgPS6yLA/s/HW9wZdLAveyPURwcUn3xcvN1zrDWlCCF75UkBYiqcRRHz3ZM
3gRoAtYiPF87Karm4tBqMNiuQbye6B2PvRnNZWJqeaOhypFi9c/WL/7WwlgVYjDk
5AG2n+ZkxKjXNMhhMcek1BhOrBYznc17jNSBXxjkYvnvP/ksQd9mP1Bjse7D5X9g
cNFNCb7sg7Nn3lW31yTNEBa9VGWvEaaewGd7iPP1WnUzmP/XTbbijrcs0hU2T/Kn
8vncz9+NxLbsGone/AyTGKbMhkiWJtBGQaZLUAh1esWWeXE3BfdQvVpxcoaOArbf
0HCMJeT27WhUajjDOXa+fbPagLud1LJaKIuhL3LMAdodCGARH2cwHDtDDa+/rphH
dGhBc/6+wn8wrPQfy/kV10wXA9SdRi79AeRdUBUruqBHqcosZTCAct/keBShDgPd
0Md2esNxFB/cHidtComC64MCAwEAAQ==
-----END PUBLIC KEY-----"""

var status := "idle"
var detail := ""
var available_manifest: Dictionary = {}

var _state: Dictionary = {}
var _base_version := "0.0.0"
var _loaded_version := ""
var _loaded_manifest: Dictionary = {}
var _booting_pending := false
var _available_envelope := PackedByteArray()
var _manifest_request: HTTPRequest
var _download_request: HTTPRequest
var _download_asset: Dictionary = {}
var _download_kind := ""
var _download_part_path := ""
var _download_final_path := ""
var _last_progress_bytes := -1
var _check_timer: Timer


func _init() -> void:
	_base_version = str(ProjectSettings.get_setting(
		"application/config/version", "0.0.0"))
	_ensure_update_dir()
	_state = _load_state()
	_mount_selected_pack()


func _ready() -> void:
	set_process(false)
	if _booting_pending:
		_confirm_pending_after_stable_boot()
	if _should_check_automatically():
		_start_periodic_checks()
		_check_after_startup()


func _process(_delta: float) -> void:
	if not _download_request or not is_instance_valid(_download_request):
		set_process(false)
		return
	var downloaded := _download_request.get_downloaded_bytes()
	if downloaded != _last_progress_bytes:
		_last_progress_bytes = downloaded
		download_progress.emit(str(available_manifest.get("version", "")),
			downloaded, int(_download_asset.get("size", 0)))


func current_version() -> String:
	return _loaded_version if not _loaded_version.is_empty() else _base_version


func effective_version() -> String:
	# Multiplayer uses this stable name in its compatibility handshake.
	return current_version()


func base_version() -> String:
	return _base_version


func loaded_content_version() -> String:
	return _loaded_version


func network_protocol() -> int:
	return int(_loaded_manifest.get("network_protocol",
		ProjectSettings.get_setting("application/config/network_protocol", 1)))


func is_update_staged() -> bool:
	return not str(_state.get("pending_version", "")).is_empty()


func staged_version() -> String:
	return str(_state.get("pending_version", ""))


func manifest_url() -> String:
	var repository := _configured_repository()
	if repository.is_empty():
		return ""
	return "https://github.com/%s/releases/latest/download/%s" % [
		repository, MANIFEST_NAME]


func check_for_updates(force := false) -> Error:
	if status in ["checking", "downloading"]:
		return ERR_BUSY
	var repository := _configured_repository()
	if repository.is_empty():
		_set_status("disabled", "No release repository is configured")
		return ERR_UNCONFIGURED
	var now := int(Time.get_unix_time_from_system())
	var last_check := int(_state.get("last_check_unix", 0))
	if not force and now - last_check < CHECK_INTERVAL_SECONDS:
		return OK
	if _manifest_request and is_instance_valid(_manifest_request):
		_manifest_request.queue_free()
	_manifest_request = HTTPRequest.new()
	_manifest_request.name = "UpdateManifestRequest"
	_manifest_request.timeout = 10.0
	_manifest_request.body_size_limit = MANIFEST_MAX_BYTES
	_manifest_request.max_redirects = 8
	_manifest_request.use_threads = true
	add_child(_manifest_request)
	_manifest_request.request_completed.connect(_on_manifest_completed)
	_set_status("checking", "Checking GitHub Releases")
	var err := _manifest_request.request(manifest_url(), PackedStringArray([
		"Accept: application/json",
		"Cache-Control: no-cache",
		"User-Agent: TROOP-Updater/%s" % current_version(),
	]))
	if err != OK:
		_manifest_request.queue_free()
		_manifest_request = null
		_fail("Could not start the update check (%d)" % err)
	return err


func download_available_update() -> Error:
	if available_manifest.is_empty():
		return ERR_DOES_NOT_EXIST
	if bool(available_manifest.get("requires_installer", false)):
		return download_installer()
	var assets: Dictionary = available_manifest.get("assets", {})
	var content: Dictionary = assets.get("content", {})
	if content.is_empty():
		return download_installer()
	return _begin_asset_download("content", content)


func download_installer() -> Error:
	if available_manifest.is_empty():
		return ERR_DOES_NOT_EXIST
	var key := _platform_asset_key()
	if key.is_empty():
		_fail("This platform does not have a TROOP installer")
		return ERR_UNAVAILABLE
	var assets: Dictionary = available_manifest.get("assets", {})
	var asset: Dictionary = assets.get(key, {})
	if asset.is_empty():
		_fail("The release does not include the %s installer" % key)
		return ERR_FILE_NOT_FOUND
	return _begin_asset_download("installer", asset)


func launch_downloaded_installer() -> bool:
	var version := str(_state.get("installer_version", ""))
	if not _valid_version(version):
		return false
	var envelope_path := _envelope_path(version)
	if not FileAccess.file_exists(envelope_path):
		return false
	var parsed := parse_signed_envelope(
		FileAccess.get_file_as_bytes(envelope_path), _configured_repository())
	if not bool(parsed.get("ok", false)) \
			or str(parsed.payload.get("version", "")) != version:
		return false
	var key := _platform_asset_key()
	var asset: Dictionary = parsed.payload.get("assets", {}).get(key, {})
	var path := UPDATE_DIR.path_join(str(asset.get("name", "")))
	if not _is_safe_update_path(path) \
			or not verify_asset_file(path, asset, INSTALLER_MAX_BYTES):
		return false
	var global_path := ProjectSettings.globalize_path(path)
	match OS.get_name():
		"Windows":
			return OS.create_process(global_path, PackedStringArray()) > 0
		"macOS":
			return OS.shell_open(global_path) == OK
	return false


func restart_to_apply() -> void:
	if not is_update_staged():
		return
	OS.set_restart_on_exit(true)
	get_tree().quit(0)


func release_page_url() -> String:
	return str(available_manifest.get("release_url", ""))


func _configured_repository() -> String:
	var repository := str(ProjectSettings.get_setting(
		"application/config/update_repository", "")).strip_edges()
	return repository if _valid_repository(repository) else ""


func _should_check_automatically() -> bool:
	if Engine.is_editor_hint() or DisplayServer.get_name() == "headless":
		return false
	if not bool(ProjectSettings.get_setting(
			"application/config/update_auto_check", true)):
		return false
	return not _configured_repository().is_empty()


func _start_periodic_checks() -> void:
	_check_timer = Timer.new()
	_check_timer.name = "UpdateCheckTimer"
	_check_timer.wait_time = CHECK_INTERVAL_SECONDS
	_check_timer.one_shot = false
	_check_timer.timeout.connect(func(): check_for_updates(false))
	add_child(_check_timer)
	_check_timer.start()


func _check_after_startup() -> void:
	await get_tree().create_timer(1.5).timeout
	# The launch check always runs. The six-hour throttle exists to pace the
	# periodic timer and menu-visit checks, but a fresh boot must see a release
	# published minutes ago — otherwise "checks on startup" silently does
	# nothing for hours after any earlier check stamped the window.
	check_for_updates(true)


func _confirm_pending_after_stable_boot() -> void:
	await get_tree().create_timer(BOOT_CONFIRM_SECONDS).timeout
	if not get_tree().current_scene:
		await get_tree().create_timer(BOOT_CONFIRM_SECONDS).timeout
	if not get_tree().current_scene:
		return
	confirm_pending_boot()


func confirm_pending_boot() -> void:
	if not _booting_pending:
		return
	var pending := str(_state.get("pending_version", ""))
	if pending.is_empty() or pending != _loaded_version:
		return
	_state["active_version"] = pending
	_state["pending_version"] = ""
	_state["pending_attempted"] = false
	_state["highest_seen_version"] = _higher_version(
		str(_state.get("highest_seen_version", _base_version)), pending)
	_booting_pending = false
	_save_state()
	_set_status("current", "TROOP %s is active" % pending)


func _mount_selected_pack() -> void:
	var pending := str(_state.get("pending_version", ""))
	if not pending.is_empty():
		if bool(_state.get("pending_attempted", false)):
			# The previous launch never reached the stability confirmation. Clear
			# only the pointer and fall back to the last known-good pack.
			_state["pending_version"] = ""
			_state["pending_attempted"] = false
			_save_state()
		else:
			_state["pending_attempted"] = true
			_save_state()
			if _verify_and_mount_version(pending):
				_booting_pending = true
				return
			_state["pending_version"] = ""
			_state["pending_attempted"] = false
			_save_state()

	var active := str(_state.get("active_version", ""))
	if active.is_empty():
		return
	if compare_versions(active, _base_version) <= 0:
		# A full installer has caught up with (or surpassed) the content pack.
		_state["active_version"] = ""
		_save_state()
		return
	if not _verify_and_mount_version(active):
		_state["active_version"] = ""
		_save_state()


func _verify_and_mount_version(version: String) -> bool:
	if not _valid_version(version) or compare_versions(version, _base_version) <= 0:
		return false
	var envelope_path := _envelope_path(version)
	var pack_path := _content_path(version)
	if not FileAccess.file_exists(envelope_path) or not FileAccess.file_exists(pack_path):
		return false
	var envelope := FileAccess.get_file_as_bytes(envelope_path)
	var parsed := parse_signed_envelope(envelope, _configured_repository())
	if not bool(parsed.get("ok", false)):
		return false
	var payload: Dictionary = parsed.payload
	if str(payload.get("version", "")) != version:
		return false
	if int(payload.get("minimum_bootstrap", 0)) > BOOTSTRAP_VERSION:
		return false
	if bool(payload.get("requires_installer", false)):
		return false
	var content: Dictionary = payload.get("assets", {}).get("content", {})
	if not verify_asset_file(pack_path, content, CONTENT_MAX_BYTES):
		return false
	if not ProjectSettings.load_resource_pack(pack_path, true):
		return false
	_loaded_version = version
	_loaded_manifest = payload
	return true


func _on_manifest_completed(result: int, response_code: int,
		_headers: PackedStringArray, body: PackedByteArray) -> void:
	if _manifest_request and is_instance_valid(_manifest_request):
		_manifest_request.queue_free()
	_manifest_request = null
	_state["last_check_unix"] = int(Time.get_unix_time_from_system())
	_save_state()
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		_fail("Update check failed (network %d, HTTP %d)" % [result, response_code])
		return
	var parsed := parse_signed_envelope(body, _configured_repository())
	if not bool(parsed.get("ok", false)):
		_fail("Rejected update manifest: %s" % str(parsed.get("error", "invalid")))
		return
	var payload: Dictionary = parsed.payload
	var version := str(payload.version)
	var highest := str(_state.get("highest_seen_version", _base_version))
	if compare_versions(version, highest) < 0:
		_fail("Rejected an older signed update manifest")
		return
	_state["highest_seen_version"] = _higher_version(highest, version)
	_save_state()
	if compare_versions(version, current_version()) <= 0:
		available_manifest = {}
		_available_envelope = PackedByteArray()
		_set_status("current", "TROOP %s is current" % current_version())
		return
	available_manifest = payload
	_available_envelope = body.duplicate()
	var requires_installer := bool(payload.get("requires_installer", false)) \
		or int(payload.get("minimum_bootstrap", 0)) > BOOTSTRAP_VERSION
	update_available.emit(version, requires_installer, str(payload.get("notes", "")))
	_set_status("available", "TROOP %s is available" % version)
	if not requires_installer and bool(ProjectSettings.get_setting(
			"application/config/update_auto_download", true)):
		download_available_update()


func _begin_asset_download(kind: String, asset: Dictionary) -> Error:
	if status == "downloading":
		return ERR_BUSY
	var version := str(available_manifest.get("version", ""))
	if not _valid_version(version):
		return ERR_INVALID_DATA
	var max_size := CONTENT_MAX_BYTES if kind == "content" else INSTALLER_MAX_BYTES
	if not _validate_asset(asset, available_manifest, kind, max_size).is_empty():
		return ERR_INVALID_DATA
	_ensure_update_dir()
	_download_kind = kind
	_download_asset = asset.duplicate(true)
	_download_final_path = _content_path(version) if kind == "content" \
		else UPDATE_DIR.path_join(str(asset.name))
	_download_part_path = _download_final_path + ".part"
	_remove_internal_file(_download_part_path)
	if _download_request and is_instance_valid(_download_request):
		_download_request.queue_free()
	_download_request = HTTPRequest.new()
	_download_request.name = "UpdateAssetRequest"
	_download_request.download_file = _download_part_path
	_download_request.body_size_limit = int(asset.size)
	_download_request.max_redirects = 8
	_download_request.timeout = 0.0
	_download_request.use_threads = true
	add_child(_download_request)
	_download_request.request_completed.connect(_on_asset_downloaded)
	_last_progress_bytes = -1
	set_process(true)
	_set_status("downloading", "Downloading TROOP %s" % version)
	var err := _download_request.request(str(asset.url), PackedStringArray([
		"Accept: application/octet-stream",
		"User-Agent: TROOP-Updater/%s" % current_version(),
	]))
	if err != OK:
		_finish_download_request()
		_remove_internal_file(_download_part_path)
		_fail("Could not start the update download (%d)" % err)
	return err


func _on_asset_downloaded(result: int, response_code: int,
		_headers: PackedStringArray, _body: PackedByteArray) -> void:
	var kind := _download_kind
	var asset := _download_asset.duplicate(true)
	var part_path := _download_part_path
	var final_path := _download_final_path
	_finish_download_request()
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		_remove_internal_file(part_path)
		_fail("Update download failed (network %d, HTTP %d)" % [result, response_code])
		return
	var max_size := CONTENT_MAX_BYTES if kind == "content" else INSTALLER_MAX_BYTES
	if not verify_asset_file(part_path, asset, max_size):
		_remove_internal_file(part_path)
		_fail("Downloaded update failed its signed size or SHA-256 check")
		return
	if FileAccess.file_exists(final_path):
		if verify_asset_file(final_path, asset, max_size):
			_remove_internal_file(part_path)
		else:
			_remove_internal_file(final_path)
	if not FileAccess.file_exists(final_path):
		var rename_err := DirAccess.rename_absolute(
			ProjectSettings.globalize_path(part_path),
			ProjectSettings.globalize_path(final_path))
		if rename_err != OK:
			_remove_internal_file(part_path)
			_fail("Could not finalize the verified update (%d)" % rename_err)
			return
	var version := str(available_manifest.version)
	if kind == "content":
		if not _write_bytes(_envelope_path(version), _available_envelope):
			_fail("Could not save the signed update receipt")
			return
		_state["pending_version"] = version
		_state["pending_attempted"] = false
		_state["highest_seen_version"] = _higher_version(
			str(_state.get("highest_seen_version", _base_version)), version)
		_save_state()
		_set_status("staged", "TROOP %s will apply on next launch" % version)
		update_staged.emit(version)
	else:
		if not _write_bytes(_envelope_path(version), _available_envelope):
			_fail("Could not save the signed installer receipt")
			return
		_state["installer_path"] = final_path
		_state["installer_version"] = version
		_save_state()
		_set_status("installer_ready", "Installer for TROOP %s is ready" % version)
		installer_ready.emit(version, final_path)


func _finish_download_request() -> void:
	set_process(false)
	if _download_request and is_instance_valid(_download_request):
		_download_request.queue_free()
	_download_request = null
	_download_kind = ""
	_download_asset = {}
	_download_part_path = ""
	_download_final_path = ""


func _set_status(next_status: String, next_detail: String) -> void:
	status = next_status
	detail = next_detail
	status_changed.emit(status, detail)


func _fail(message: String) -> void:
	_set_status("error", message)
	update_error.emit(message)


func _ensure_update_dir() -> bool:
	var global_path := ProjectSettings.globalize_path(UPDATE_DIR)
	return DirAccess.make_dir_recursive_absolute(global_path) == OK \
		or DirAccess.dir_exists_absolute(global_path)


func _load_state() -> Dictionary:
	var defaults := {
		"schema": STATE_SCHEMA,
		"active_version": "",
		"pending_version": "",
		"pending_attempted": false,
		"highest_seen_version": _base_version,
		"last_check_unix": 0,
		"installer_path": "",
		"installer_version": "",
	}
	if not FileAccess.file_exists(STATE_PATH):
		return defaults
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(STATE_PATH))
	if typeof(parsed) != TYPE_DICTIONARY or int(parsed.get("schema", 0)) != STATE_SCHEMA:
		return defaults
	for key in defaults:
		if not parsed.has(key):
			parsed[key] = defaults[key]
	if not _valid_version_or_empty(str(parsed.active_version)):
		parsed.active_version = ""
	if not _valid_version_or_empty(str(parsed.pending_version)):
		parsed.pending_version = ""
	if not _valid_version(str(parsed.highest_seen_version)):
		parsed.highest_seen_version = _base_version
	if not _is_safe_update_path(str(parsed.installer_path)):
		parsed.installer_path = ""
	return parsed


func _save_state() -> bool:
	_state["schema"] = STATE_SCHEMA
	return _write_bytes(STATE_PATH, JSON.stringify(_state, "  ").to_utf8_buffer())


func _write_bytes(path: String, bytes: PackedByteArray) -> bool:
	if not _is_safe_update_path(path):
		return false
	var file := FileAccess.open(path, FileAccess.WRITE)
	if not file:
		return false
	file.store_buffer(bytes)
	file.close()
	return FileAccess.get_open_error() == OK


func _remove_internal_file(path: String) -> void:
	if not _is_safe_update_path(path) or not FileAccess.file_exists(path):
		return
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _content_path(version: String) -> String:
	return UPDATE_DIR.path_join("TROOP-%s-content.pck" % version)


func _envelope_path(version: String) -> String:
	return UPDATE_DIR.path_join("TROOP-%s-update.json" % version)


func _is_safe_update_path(path: String) -> bool:
	return path == STATE_PATH or path.begins_with(UPDATE_DIR + "/") \
		and path.find("..") == -1 and not path.contains("\\")


func _platform_asset_key() -> String:
	match OS.get_name():
		"Windows":
			return "windows"
		"macOS":
			return "macos"
	return ""


static func compare_versions(left: String, right: String) -> int:
	var a := _version_parts(left)
	var b := _version_parts(right)
	if a.is_empty() or b.is_empty():
		return 0
	for i in range(4):
		if a[i] < b[i]:
			return -1
		if a[i] > b[i]:
			return 1
	return 0


static func parse_signed_envelope(envelope_bytes: PackedByteArray,
		expected_repository := "") -> Dictionary:
	if envelope_bytes.is_empty() or envelope_bytes.size() > MANIFEST_MAX_BYTES:
		return _parse_failure("envelope size")
	var envelope = JSON.parse_string(envelope_bytes.get_string_from_utf8())
	if typeof(envelope) != TYPE_DICTIONARY:
		return _parse_failure("envelope JSON")
	if str(envelope.get("algorithm", "")) != "rsa-pkcs1v15-sha256":
		return _parse_failure("signature algorithm")
	if str(envelope.get("key_id", "")) != "troop-update-rsa-2026-01":
		return _parse_failure("key id")
	var payload_bytes := Marshalls.base64_to_raw(str(envelope.get("payload", "")))
	var signature := Marshalls.base64_to_raw(str(envelope.get("signature", "")))
	if payload_bytes.is_empty() or signature.is_empty():
		return _parse_failure("base64")
	var public_key := CryptoKey.new()
	if public_key.load_from_string(UPDATE_PUBLIC_KEY_PEM, true) != OK \
			or not public_key.is_public_only():
		return _parse_failure("embedded public key")
	var digest := _sha256_bytes(payload_bytes)
	if digest.is_empty() or not Crypto.new().verify(
			HashingContext.HASH_SHA256, digest, signature, public_key):
		return _parse_failure("signature")
	var payload = JSON.parse_string(payload_bytes.get_string_from_utf8())
	if typeof(payload) != TYPE_DICTIONARY:
		return _parse_failure("payload JSON")
	var validation_error := _validate_payload(payload, expected_repository)
	if not validation_error.is_empty():
		return _parse_failure(validation_error)
	return {"ok": true, "error": "", "payload": payload}


static func verify_asset_file(path: String, asset: Dictionary,
		max_size: int) -> bool:
	if not FileAccess.file_exists(path):
		return false
	var expected_size := int(asset.get("size", -1))
	if expected_size <= 0 or expected_size > max_size:
		return false
	var file := FileAccess.open(path, FileAccess.READ)
	if not file or file.get_length() != expected_size:
		return false
	file.close()
	return _sha256_file(path) == str(asset.get("sha256", "")).to_lower()


static func _validate_payload(payload: Dictionary,
		expected_repository: String) -> String:
	if int(payload.get("schema", 0)) != MANIFEST_SCHEMA:
		return "schema"
	if str(payload.get("app_id", "")) != APP_ID:
		return "app id"
	if str(payload.get("channel", "")) != CHANNEL:
		return "channel"
	var version := str(payload.get("version", ""))
	if not _valid_version(version):
		return "version"
	var repository := str(payload.get("repository", ""))
	if not _valid_repository(repository):
		return "repository"
	if not expected_repository.is_empty() and repository != expected_repository:
		return "repository mismatch"
	if str(payload.get("tag", "")) != "v" + version:
		return "tag"
	if str(payload.get("release_url", "")) != \
			"https://github.com/%s/releases/tag/v%s" % [repository, version]:
		return "release URL"
	var minimum_bootstrap = payload.get("minimum_bootstrap", 0)
	if not _whole_number(minimum_bootstrap) or int(minimum_bootstrap) < 1:
		return "minimum bootstrap"
	if typeof(payload.get("requires_installer", null)) != TYPE_BOOL:
		return "installer policy"
	if str(payload.get("godot_compatibility", "")) != _engine_compatibility() \
			and not bool(payload.requires_installer):
		return "engine compatibility"
	var network_protocol = payload.get("network_protocol", 0)
	if not _whole_number(network_protocol) or int(network_protocol) < 1:
		return "network protocol"
	if typeof(payload.get("notes", "")) != TYPE_STRING \
			or str(payload.get("notes", "")).length() > 4096:
		return "notes"
	var assets = payload.get("assets", {})
	if typeof(assets) != TYPE_DICTIONARY:
		return "assets"
	var content_error := _validate_asset(
		assets.get("content", {}), payload, "content", CONTENT_MAX_BYTES)
	if not content_error.is_empty():
		return content_error
	for kind in ["windows", "macos"]:
		var installer_error := _validate_asset(
			assets.get(kind, {}), payload, kind, INSTALLER_MAX_BYTES)
		if not installer_error.is_empty():
			return installer_error
	return ""


static func _validate_asset(asset, payload: Dictionary, kind: String,
		max_size: int) -> String:
	if typeof(asset) != TYPE_DICTIONARY:
		return "%s asset" % kind
	var version := str(payload.get("version", ""))
	var expected_name := ""
	match kind:
		"content":
			expected_name = "TROOP-%s-content.pck" % version
		"windows":
			expected_name = "TROOP-%s-Windows-x86_64-Setup.exe" % version
		"macos":
			expected_name = "TROOP-%s-macOS-universal.dmg" % version
		"installer":
			expected_name = str(asset.get("name", ""))
		_:
			return "asset kind"
	if str(asset.get("name", "")) != expected_name:
		return "%s asset name" % kind
	var repository := str(payload.get("repository", ""))
	var expected_url := "https://github.com/%s/releases/download/v%s/%s" % [
		repository, version, expected_name]
	if str(asset.get("url", "")) != expected_url:
		return "%s asset URL" % kind
	var size = asset.get("size", 0)
	if not _whole_number(size) or int(size) <= 0 or int(size) > max_size:
		return "%s asset size" % kind
	if not _valid_sha256(str(asset.get("sha256", ""))):
		return "%s asset hash" % kind
	return ""


static func _sha256_bytes(bytes: PackedByteArray) -> PackedByteArray:
	var hashing := HashingContext.new()
	if hashing.start(HashingContext.HASH_SHA256) != OK \
			or hashing.update(bytes) != OK:
		return PackedByteArray()
	return hashing.finish()


static func _sha256_file(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if not file:
		return ""
	var hashing := HashingContext.new()
	if hashing.start(HashingContext.HASH_SHA256) != OK:
		file.close()
		return ""
	while file.get_position() < file.get_length():
		var remaining := file.get_length() - file.get_position()
		var chunk := file.get_buffer(mini(HASH_CHUNK_BYTES, remaining))
		if chunk.is_empty() or hashing.update(chunk) != OK:
			file.close()
			return ""
	file.close()
	return hashing.finish().hex_encode()


static func _version_parts(version: String) -> Array[int]:
	var raw := version.split(".")
	if raw.size() not in [3, 4]:
		return []
	var parts: Array[int] = []
	for token in raw:
		if token.is_empty() or not token.is_valid_int() or token.begins_with("-"):
			return []
		if token.length() > 1 and token.begins_with("0"):
			return []
		var value := token.to_int()
		if value < 0 or value > 2147483647:
			return []
		parts.append(value)
	while parts.size() < 4:
		parts.append(0)
	return parts


static func _valid_version(version: String) -> bool:
	return not _version_parts(version).is_empty()


static func _valid_version_or_empty(version: String) -> bool:
	return version.is_empty() or _valid_version(version)


static func _higher_version(left: String, right: String) -> String:
	return right if compare_versions(right, left) > 0 else left


static func _valid_repository(repository: String) -> bool:
	var parts := repository.split("/")
	if parts.size() != 2 or parts[0].is_empty() or parts[1].is_empty():
		return false
	for part in parts:
		if part.length() > 100:
			return false
		for character in part:
			if not (character >= "a" and character <= "z") \
					and not (character >= "A" and character <= "Z") \
					and not (character >= "0" and character <= "9") \
					and character not in ["-", "_", "."]:
				return false
	return true


static func _valid_sha256(value: String) -> bool:
	if value.length() != 64:
		return false
	for character in value.to_lower():
		if character not in "0123456789abcdef":
			return false
	return true


static func _whole_number(value) -> bool:
	return typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT \
		and is_finite(float(value)) and float(value) == floor(float(value))


static func _engine_compatibility() -> String:
	var version := Engine.get_version_info()
	return "%d.%d" % [int(version.major), int(version.minor)]


static func _parse_failure(message: String) -> Dictionary:
	return {"ok": false, "error": message, "payload": {}}
