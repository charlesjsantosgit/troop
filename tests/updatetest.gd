extends SceneTree
## Offline updater security checks. Run with:
## godot --headless --path . --script res://tests/updatetest.gd

const UpdaterScript = preload("res://scripts/updater.gd")
const VALID_ENVELOPE := "res://tests/fixtures/update-valid.json"
const HASH_FIXTURE := "res://tests/fixtures/update-hash.txt"
const HASH_FIXTURE_SHA256 := "da18d85ec458ab9ede256bc331068a23f8772af0d29ea857273de3b656249a86"

var assertions := 0
var failures := 0


func _initialize() -> void:
	if OS.has_feature("editor"):
		var source_updater := UpdaterScript.new()
		_check(source_updater.status == "source", "source build is labeled honestly")
		_check(source_updater._state.is_empty(), "source build does not load installed update state")
		_check(not source_updater._should_check_automatically(), "source build disables automatic checks")
		_check(source_updater.check_for_updates(true) == ERR_UNAVAILABLE,
			"forced source checks cannot mutate installed update state")
		source_updater.free()
	var envelope_bytes := FileAccess.get_file_as_bytes(VALID_ENVELOPE)
	_check(not envelope_bytes.is_empty(), "signed fixture is readable")

	var parsed: Dictionary = UpdaterScript.parse_signed_envelope(
		envelope_bytes, "example/troop")
	_check(bool(parsed.get("ok", false)), "valid RSA-signed envelope verifies")
	var payload: Dictionary = parsed.get("payload", {})
	_check(str(payload.get("version", "")) == "9.8.7", "signed version survives parsing")
	_check(int(payload.get("minimum_bootstrap", 0)) == 1,
		"bootstrap compatibility is present")
	_check(int(payload.get("network_protocol", 0)) == 1,
		"network protocol is present")

	var wrong_repo: Dictionary = UpdaterScript.parse_signed_envelope(
		envelope_bytes, "attacker/troop")
	_check(not bool(wrong_repo.get("ok", false)), "repository substitution is rejected")

	var envelope = JSON.parse_string(envelope_bytes.get_string_from_utf8())
	var signature: String = str(envelope.signature)
	envelope.signature = ("A" if not signature.begins_with("A") else "B") \
		+ signature.substr(1)
	var bad_signature := JSON.stringify(envelope).to_utf8_buffer()
	var rejected: Dictionary = UpdaterScript.parse_signed_envelope(
		bad_signature, "example/troop")
	_check(not bool(rejected.get("ok", false)), "modified signature is rejected")

	envelope = JSON.parse_string(envelope_bytes.get_string_from_utf8())
	var payload_bytes := Marshalls.base64_to_raw(str(envelope.payload))
	payload_bytes[10] = payload_bytes[10] ^ 1
	envelope.payload = Marshalls.raw_to_base64(payload_bytes)
	var bad_payload := JSON.stringify(envelope).to_utf8_buffer()
	rejected = UpdaterScript.parse_signed_envelope(bad_payload, "example/troop")
	_check(not bool(rejected.get("ok", false)), "modified payload is rejected")

	_check(UpdaterScript.compare_versions("1.2.0", "1.1.99") > 0,
		"numeric versions compare by component")
	_check(UpdaterScript.compare_versions("1.2.0", "1.2.0.0") == 0,
		"optional fourth zero component is equivalent")
	_check(UpdaterScript.compare_versions("1.10.0", "1.9.9") > 0,
		"versions are not compared lexically")
	_check(not UpdaterScript._valid_version("1.02.3"),
		"ambiguous leading-zero version is rejected")
	_check(not UpdaterScript._valid_version("1.2.3-beta"),
		"unsigned prerelease syntax is rejected on stable channel")

	var fixture_size := FileAccess.get_file_as_bytes(HASH_FIXTURE).size()
	var valid_asset := {
		"size": fixture_size,
		"sha256": HASH_FIXTURE_SHA256,
	}
	_check(UpdaterScript.verify_asset_file(HASH_FIXTURE, valid_asset, 1024),
		"streamed file size and SHA-256 verification passes")
	valid_asset.sha256 = "0".repeat(64)
	_check(not UpdaterScript.verify_asset_file(HASH_FIXTURE, valid_asset, 1024),
		"hash mismatch is rejected")
	valid_asset.sha256 = HASH_FIXTURE_SHA256
	valid_asset.size = fixture_size + 1
	_check(not UpdaterScript.verify_asset_file(HASH_FIXTURE, valid_asset, 1024),
		"size mismatch is rejected")
	valid_asset.size = fixture_size
	_check(not UpdaterScript.verify_asset_file(HASH_FIXTURE, valid_asset, 4),
		"configured download size ceiling is enforced")

	if failures > 0:
		push_error("UPDATETEST FAIL assertions=%d failures=%d" % [assertions, failures])
		quit(1)
	else:
		print("UPDATETEST PASS assertions=%d" % assertions)
		quit(0)


func _check(condition: bool, label: String) -> void:
	if not condition:
		failures += 1
		push_error("UPDATETEST ASSERTION: " + label)
		return
	assertions += 1
