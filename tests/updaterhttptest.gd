extends SceneTree
## Driven only by run_updater_http.py in a minimal isolated project. The actual
## updater factories are exercised against a loopback server that stalls after
## accepting headers or sending a partial body. No release URL is requested.

const UpdaterScript = preload("res://scripts/updater.gd")
const TEST_TIMEOUT_SECONDS := 0.5
const MAX_COMPLETION_MSEC := 1000.0
const MAX_FRAME_GAP_MSEC := 250.0
const MAX_CANCEL_MSEC := 100.0
const BODY_BYTES := 1024
const CASES := ["manifest_headers", "manifest_body", "cancel_headers",
	"cancel_body", "teardown_headers", "teardown_body"]

var case_name := ""
var checks := 0
var failures: Array[String] = []
var completions: Array[int] = []
var completed_usec := 0
var started_usec := 0
var last_frame_usec := 0
var last_heartbeat_usec := 0
var max_gap_usec := 0
var cancel_usec := 0


func _initialize() -> void:
	process_frame.connect(_on_frame)
	call_deferred("_run")


func _on_frame() -> void:
	var now := Time.get_ticks_usec()
	if started_usec <= 0:
		return
	max_gap_usec = maxi(max_gap_usec, now - last_frame_usec)
	last_frame_usec = now
	if now - last_heartbeat_usec >= 100000:
		last_heartbeat_usec = now
		print("UPDATERHTTPTEST HEARTBEAT case=%s elapsed_ms=%.3f" % [
			case_name, (now - started_usec) / 1000.0])


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 2 or str(args[0]) not in CASES \
			or not str(args[1]).is_valid_int():
		push_error("UPDATERHTTPTEST requires a known case and loopback port")
		quit(1)
		return
	case_name = str(args[0])
	var port := int(args[1])
	if port < 1 or port > 65535:
		push_error("UPDATERHTTPTEST invalid loopback port")
		quit(1)
		return
	# Exclude engine startup's first frame delta from the short test timer.
	for _frame in range(6):
		await process_frame
	var updater := UpdaterScript.new()
	var manifest_case := case_name.begins_with("manifest_")
	var part_path := "res://%s.part" % case_name
	var request: HTTPRequest = updater._create_manifest_request() if manifest_case \
		else updater._create_asset_request(BODY_BYTES, part_path)
	_check(not request.use_threads, "request uses nonblocking polling")
	_check(request.max_redirects == 8, "redirect bound is unchanged")
	if manifest_case:
		_check(is_equal_approx(request.timeout, 10.0), "manifest production timeout is ten seconds")
		_check(request.body_size_limit == UpdaterScript.MANIFEST_MAX_BYTES,
			"manifest body ceiling is unchanged")
		_check(request.download_file.is_empty(), "manifest remains memory-only")
		request.timeout = TEST_TIMEOUT_SECONDS
	else:
		_check(is_zero_approx(request.timeout), "asset has no arbitrary total download deadline")
		_check(request.body_size_limit == BODY_BYTES, "asset keeps its signed size ceiling")
		_check(request.download_file == part_path, "asset keeps its isolated partial-file path")
	root.add_child(request)
	request.request_completed.connect(_on_completed)
	started_usec = Time.get_ticks_usec()
	last_frame_usec = started_usec
	last_heartbeat_usec = started_usec
	var error := request.request("http://127.0.0.1:%d/stall" % port)
	_check(error == OK, "loopback request starts")
	if error == OK:
		if manifest_case:
			while completions.is_empty() and Time.get_ticks_usec() - started_usec < 4000000:
				await process_frame
			_check(completions == [HTTPRequest.RESULT_TIMEOUT], "manifest reports exactly one timeout")
			_check(completed_usec > 0 and (completed_usec - started_usec) / 1000.0 \
				<= MAX_COMPLETION_MSEC, "manifest timeout returns within the wall-clock bound")
		else:
			while Time.get_ticks_usec() - started_usec < roundi(TEST_TIMEOUT_SECONDS * 1000000.0):
				await process_frame
			if case_name.ends_with("_body"):
				_check(FileAccess.file_exists(part_path), "partial download exists before cancellation")
			var cancel_started := Time.get_ticks_usec()
			if case_name.begins_with("teardown_"):
				request.free()
				request = null
			else:
				request.cancel_request()
			cancel_usec = Time.get_ticks_usec() - cancel_started
			_check(cancel_usec / 1000.0 <= MAX_CANCEL_MSEC, "cancel or node teardown returns immediately")
			_check(not FileAccess.file_exists(part_path), "canceled partial file is removed")
	# Include the frame after timeout/cancellation, where a worker-join stall is
	# visible, and ensure cancellation does not emit a late completion callback.
	for _frame in range(3):
		await process_frame
	if not manifest_case:
		_check(completions.is_empty(), "cancel or teardown has no late completion")
	_check(max_gap_usec / 1000.0 <= MAX_FRAME_GAP_MSEC, "frame heartbeat remains responsive")
	if is_instance_valid(request):
		request.free()
	updater.free()
	print("UPDATERHTTPTEST %s %s checks=%d/%d elapsed_ms=%.3f max_gap_ms=%.3f cancel_ms=%.3f results=%s" % [
		case_name, "PASS" if failures.is_empty() else "FAIL", checks - failures.size(),
		checks, (Time.get_ticks_usec() - started_usec) / 1000.0,
		max_gap_usec / 1000.0, cancel_usec / 1000.0, completions])
	quit(0 if failures.is_empty() else 1)


func _on_completed(result: int, _response_code: int,
		_headers: PackedStringArray, _body: PackedByteArray) -> void:
	completions.append(result)
	if completed_usec == 0:
		completed_usec = Time.get_ticks_usec()


func _check(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures.append(label)
		push_error("UPDATERHTTPTEST %s: %s" % [case_name, label])
