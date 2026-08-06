class_name VoiceChat
extends Node
## Low-latency, proximity push-to-talk using Godot's microphone input.
##
## Transmission is active only while the bound PTT action is held in an online
## world. The input device stays warm briefly after release so quick PTT toggles
## do not reconfigure the platform audio graph and hitch the render thread.
## Frames are downsampled to 16 kHz mono, independently IMA-ADPCM encoded, and
## sent through Net's isolated unreliable channel. Each remote speaker gets a
## short prebuffer and a positional AudioStreamGenerator attached to the world.

signal local_talking_changed(active: bool)
signal speaker_talking_changed(peer_id: int, active: bool)
signal microphone_error(message: String)

const PACKET_SECONDS := 0.020
const TARGET_SAMPLES := VoiceCodec.RECOMMENDED_FRAME_SAMPLES
const PREBUFFER_PACKETS := 3
const TALKING_TIMEOUT_MSEC := 220
const SPEAKER_RETIRE_MSEC := 5000
const MAX_CAPTURE_PACKETS_PER_FRAME := 4
const MAX_DECODED_QUEUE_PACKETS := 8
const INPUT_IDLE_RELEASE_MSEC := 850
const MAX_DISCARD_FRAMES_PER_TICK := 4096

var local_talking := false
var _capture_active := false
var _input_device_active := false
var _input_release_deadline_msec := 0
var _sequence := 0
var _world: Node
var _speakers: Dictionary = {}
var _muted_peers: Dictionary = {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	Net.voice_packet.connect(_on_voice_packet)
	Net.peer_left.connect(_on_peer_left)
	set_process(true)


func _exit_tree() -> void:
	_stop_capture(true)
	clear_world()


func attach_world(world_node: Node) -> void:
	if _world == world_node:
		return
	clear_world()
	_world = world_node


func clear_world() -> void:
	_stop_capture(true)
	for peer_id in _speakers.keys():
		_remove_speaker(int(peer_id), false)
	_speakers.clear()
	_world = null


func set_peer_muted(peer_id: int, muted: bool) -> void:
	if muted:
		_muted_peers[peer_id] = true
		_remove_speaker(peer_id, true)
	else:
		_muted_peers.erase(peer_id)


func is_peer_muted(peer_id: int) -> bool:
	return _muted_peers.has(peer_id)


func is_peer_talking(peer_id: int) -> bool:
	return _speakers.has(peer_id) and bool(_speakers[peer_id].get("talking", false))


func speaking_peers() -> Array:
	var result: Array = []
	for peer_id in _speakers:
		if bool(_speakers[peer_id].get("talking", false)):
			result.append(peer_id)
	return result


func _process(_dt: float) -> void:
	var should_talk := Net.active and not Net.is_dedicated \
		and _world != null and is_instance_valid(_world) \
		and InputMap.has_action("push_to_talk") \
		and Input.is_action_pressed("push_to_talk") \
		and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	if should_talk and not _capture_active:
		_start_capture()
	elif not should_talk and _capture_active:
		_stop_capture()
	if _capture_active:
		_capture_packets()
	elif _input_device_active:
		# Drain while idle so a quick re-press starts with current speech, without
		# an unbounded buffer-clearing loop on the input event frame.
		_discard_input_frames(MAX_DISCARD_FRAMES_PER_TICK)
		if input_release_due(Time.get_ticks_msec(),
				_input_release_deadline_msec):
			_deactivate_input_device()
	_update_speakers()


func _start_capture() -> void:
	_input_release_deadline_msec = 0
	if not _input_device_active:
		var err := AudioServer.set_input_device_active(true)
		if err != OK:
			microphone_error.emit("Microphone unavailable (%d). Check system privacy settings." % err)
			return
		_input_device_active = true
	_capture_active = true
	_set_local_talking(true)


func _stop_capture(immediate := false) -> void:
	_capture_active = false
	_set_local_talking(false)
	if not _input_device_active:
		return
	if immediate:
		_deactivate_input_device()
	else:
		_input_release_deadline_msec = Time.get_ticks_msec() \
			+ INPUT_IDLE_RELEASE_MSEC


func _deactivate_input_device() -> void:
	if _input_device_active:
		AudioServer.set_input_device_active(false)
	_input_device_active = false
	_input_release_deadline_msec = 0


static func input_release_due(now_msec: int, deadline_msec: int) -> bool:
	return deadline_msec > 0 and now_msec >= deadline_msec


func _set_local_talking(active: bool) -> void:
	if local_talking == active:
		return
	local_talking = active
	local_talking_changed.emit(active)


func _capture_packets() -> void:
	var input_rate := AudioServer.get_input_mix_rate()
	if not is_finite(input_rate) or input_rate < 8000.0:
		return
	var source_count := maxi(1, roundi(input_rate * PACKET_SECONDS))
	var sent := 0
	while AudioServer.get_input_frames_available() >= source_count \
			and sent < MAX_CAPTURE_PACKETS_PER_FRAME:
		var source := AudioServer.get_input_frames(source_count)
		if source.size() != source_count:
			break
		var mono := _resample_mono(source, TARGET_SAMPLES)
		var packet := VoiceCodec.encode(mono)
		if not packet.is_empty():
			Net.send_voice(_sequence, packet)
			_sequence = (_sequence + 1) & 0x7fffffff
		sent += 1


func _resample_mono(source: PackedVector2Array,
		target_count: int) -> PackedFloat32Array:
	var result := PackedFloat32Array()
	if source.is_empty() or target_count <= 0:
		return result
	result.resize(target_count)
	var ratio := float(source.size()) / float(target_count)
	for i in range(target_count):
		var source_position := clampf((float(i) + 0.5) * ratio - 0.5,
			0.0, float(source.size() - 1))
		var first := floori(source_position)
		var second := mini(first + 1, source.size() - 1)
		var fraction := source_position - float(first)
		var a := (source[first].x + source[first].y) * 0.5
		var b := (source[second].x + source[second].y) * 0.5
		# Modest gain makes laptop microphones readable; hard clipping is handled by
		# VoiceCodec and prevents malformed or dangerously loud output.
		result[i] = clampf(lerpf(a, b, fraction) * 1.28, -1.0, 1.0)
	return result


func _discard_input_frames(max_frames: int) -> void:
	var available := AudioServer.get_input_frames_available()
	if available > 0:
		AudioServer.get_input_frames(mini(available, maxi(max_frames, 0)))


func _on_voice_packet(peer_id: int, sequence: int,
		payload: PackedByteArray) -> void:
	if _world == null or not is_instance_valid(_world) \
			or _muted_peers.has(peer_id) or peer_id == Net.local_id():
		return
	var decoded := VoiceCodec.decode(payload)
	if not bool(decoded.ok):
		return
	var samples: PackedFloat32Array = decoded.samples
	if samples.is_empty():
		return
	var entry := _ensure_speaker(peer_id, sequence)
	if entry.is_empty():
		return
	var last_sequence := int(entry.last_sequence)
	if sequence <= last_sequence:
		return
	var missing := mini(sequence - last_sequence - 1, 3)
	if entry.queue.size() + missing + 1 > MAX_DECODED_QUEUE_PACKETS:
		# A stalled audio device must not turn decoded voice into an unbounded queue.
		# Drop stale latency, stop the old playback handle, and prebuffer anew from
		# this current packet rather than replaying obsolete silence or speech.
		entry = _reset_speaker_stream(entry)
		missing = 0
	for _i in range(missing):
		entry.queue.append(_empty_frames(TARGET_SAMPLES))
	entry.queue.append(_samples_to_frames(samples))
	entry.last_sequence = sequence
	entry.last_received = Time.get_ticks_msec()
	if not bool(entry.talking):
		entry.talking = true
		speaker_talking_changed.emit(peer_id, true)
	_speakers[peer_id] = entry
	_flush_speaker(peer_id)


func _ensure_speaker(peer_id: int, first_sequence: int) -> Dictionary:
	if _speakers.has(peer_id):
		return _speakers[peer_id]
	if _world == null or not is_instance_valid(_world):
		return {}
	var generator := AudioStreamGenerator.new()
	generator.mix_rate_mode = AudioStreamGenerator.MIX_RATE_CUSTOM
	generator.mix_rate = float(VoiceCodec.SAMPLE_RATE_HZ)
	generator.buffer_length = 0.30
	var player := AudioStreamPlayer3D.new()
	player.name = "Voice_%d" % peer_id
	player.stream = generator
	player.bus = &"Voice"
	player.attenuation_model = AudioStreamPlayer3D.ATTENUATION_LOGARITHMIC
	player.unit_size = 4.0
	player.max_distance = 58.0
	player.max_db = 2.0
	player.panning_strength = 0.72
	_world.add_child(player)
	return {
		"player": player,
		"playback": null,
		"queue": [],
		"started": false,
		"talking": false,
		"last_sequence": first_sequence - 1,
		"last_received": Time.get_ticks_msec(),
	}


func _flush_speaker(peer_id: int) -> void:
	if not _speakers.has(peer_id):
		return
	var entry: Dictionary = _speakers[peer_id]
	var player := entry.player as AudioStreamPlayer3D
	if not is_instance_valid(player):
		_remove_speaker(peer_id, true)
		return
	var queue: Array = entry.queue
	if not bool(entry.started):
		if queue.size() < PREBUFFER_PACKETS:
			_speakers[peer_id] = entry
			return
		player.play()
		entry.playback = player.get_stream_playback()
		entry.started = entry.playback != null
	var playback = entry.playback
	if playback != null:
		while not queue.is_empty():
			var frames: PackedVector2Array = queue[0]
			if playback.get_frames_available() < frames.size():
				break
			playback.push_buffer(frames)
			queue.pop_front()
	entry.queue = queue
	_speakers[peer_id] = entry


func _update_speakers() -> void:
	var now := Time.get_ticks_msec()
	for peer_id_value in _speakers.keys():
		var peer_id := int(peer_id_value)
		if not _speakers.has(peer_id):
			continue
		var entry: Dictionary = _speakers[peer_id]
		var player := entry.player as AudioStreamPlayer3D
		if not is_instance_valid(player):
			_remove_speaker(peer_id, true)
			continue
		var puppet := _remote_actor(peer_id)
		if puppet and is_instance_valid(puppet):
			player.global_position = puppet.global_position + Vector3.UP * 1.15
		_flush_speaker(peer_id)
		var idle_msec := now - int(entry.last_received)
		if idle_msec > TALKING_TIMEOUT_MSEC and bool(entry.talking):
			entry.talking = false
			entry = _reset_speaker_stream(entry)
			_speakers[peer_id] = entry
			speaker_talking_changed.emit(peer_id, false)
		if idle_msec > SPEAKER_RETIRE_MSEC:
			_remove_speaker(peer_id, false)


func _remote_actor(peer_id: int) -> Node3D:
	if _world == null or not is_instance_valid(_world):
		return null
	var puppets: Dictionary = _world.get("puppets")
	var actor = puppets.get(peer_id)
	return actor as Node3D if is_instance_valid(actor) else null


func _on_peer_left(peer_id: int) -> void:
	_remove_speaker(peer_id, true)
	_muted_peers.erase(peer_id)


func _reset_speaker_stream(entry: Dictionary) -> Dictionary:
	var player = entry.get("player")
	if is_instance_valid(player):
		player.stop()
	entry.queue = []
	entry.started = false
	entry.playback = null
	return entry


func _remove_speaker(peer_id: int, emit_stopped: bool) -> void:
	if not _speakers.has(peer_id):
		return
	var entry: Dictionary = _speakers[peer_id]
	if emit_stopped and bool(entry.get("talking", false)):
		speaker_talking_changed.emit(peer_id, false)
	var player = entry.get("player")
	if is_instance_valid(player):
		player.queue_free()
	_speakers.erase(peer_id)


func _empty_frames(count: int) -> PackedVector2Array:
	var frames := PackedVector2Array()
	frames.resize(count)
	return frames


func _silent_frames(count: int) -> PackedVector2Array:
	return _empty_frames(count)


func _stereo_frames_from_sample(sample: float) -> Vector2:
	return Vector2(sample, sample)


func _samples_to_frames(samples: PackedFloat32Array) -> PackedVector2Array:
	var frames := PackedVector2Array()
	frames.resize(samples.size())
	for i in range(samples.size()):
		frames[i] = _stereo_frames_from_sample(samples[i])
	return frames
