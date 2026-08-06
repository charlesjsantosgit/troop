extends SceneTree
## Standalone headless checks:
##   godot --headless --path . --script res://tests/voicetest.gd

const Codec = preload("res://scripts/voice_codec.gd")

var passed := 0
var total := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_format_and_quality()
	_test_packet_independence()
	_test_input_bounds()
	_test_malformed_packets()
	print("VOICETEST %d/%d %s" % [
		passed, total, "PASS" if passed == total else "FAIL"])
	quit(0 if passed == total else 1)


func _test_format_and_quality() -> void:
	var silence := PackedFloat32Array()
	silence.resize(Codec.RECOMMENDED_FRAME_SAMPLES)
	var silence_packet: PackedByteArray = Codec.encode(silence)
	var silence_result: Dictionary = Codec.decode(silence_packet)
	_check(bool(silence_result.ok) \
		and silence_packet.size() == Codec.expected_packet_size(silence.size()) \
		and silence_packet.size() <= Codec.MAX_PACKET_BYTES,
		"20 ms mono frame has the exact bounded packet size")
	_check(_max_abs(silence_result.samples) == 0.0,
		"digital silence round-trips exactly")

	var tone := _voice_tone(440.0, 0.72, Codec.RECOMMENDED_FRAME_SAMPLES, 0.0)
	var tone_packet: PackedByteArray = Codec.encode(tone)
	var tone_result: Dictionary = Codec.decode(tone_packet)
	var tone_error := _mean_abs_error(tone, tone_result.samples) \
		if bool(tone_result.ok) else INF
	_check(bool(tone_result.ok) and tone_result.samples.size() == tone.size() \
		and int(tone_result.sample_rate) == 16000 \
		and int(tone_result.channels) == 1,
		"packet declares and decodes 16 kHz mono with the original sample count")
	_check(tone_error < 0.02,
		"IMA ADPCM tone round-trip stays below 0.02 mean error (%.5f)" % tone_error)
	_check(tone_packet == Codec.encode(tone),
		"encoding is deterministic")

	var one := PackedInt32Array([-32768])
	var one_result: Dictionary = Codec.decode_pcm16(Codec.encode_pcm16(one))
	_check(bool(one_result.ok) and one_result.samples == one,
		"single-sample boundary frame preserves its predictor exactly")


func _test_packet_independence() -> void:
	var first := _voice_tone(180.0, 0.55, Codec.RECOMMENDED_FRAME_SAMPLES, 0.2)
	var second := _voice_tone(710.0, 0.43, Codec.RECOMMENDED_FRAME_SAMPLES, 1.1)
	var first_packet: PackedByteArray = Codec.encode(first)
	var second_packet: PackedByteArray = Codec.encode(second)
	var second_before: Dictionary = Codec.decode(second_packet)
	Codec.decode(first_packet)
	var second_after: Dictionary = Codec.decode(second_packet)
	_check(bool(second_before.ok) and bool(second_after.ok) \
		and second_before.samples == second_after.samples,
		"each frame decodes identically without predecessor state")
	_check(_mean_abs_error(second, second_before.samples) < 0.02,
		"independent second frame retains voice-band quality")


func _test_input_bounds() -> void:
	_check(Codec.encode(PackedFloat32Array()).is_empty(),
		"empty input is rejected")
	var too_many := PackedFloat32Array()
	too_many.resize(Codec.MAX_FRAME_SAMPLES + 1)
	_check(Codec.encode(too_many).is_empty(),
		"frames above the 640-sample ceiling are rejected")
	var non_finite := PackedFloat32Array([0.0, NAN, 0.0])
	_check(Codec.encode(non_finite).is_empty(),
		"non-finite capture samples are rejected")
	_check(Codec.encode_pcm16(PackedInt32Array([0, 32768])).is_empty(),
		"out-of-range PCM16 input is rejected")
	var maximum := _voice_tone(260.0, 0.6, Codec.MAX_FRAME_SAMPLES, 0.4)
	var maximum_packet: PackedByteArray = Codec.encode(maximum)
	_check(not maximum_packet.is_empty() \
		and maximum_packet.size() == Codec.MAX_PACKET_BYTES,
		"maximum legal frame fits the hard packet bound")


func _test_malformed_packets() -> void:
	var source := _voice_tone(330.0, 0.5, Codec.RECOMMENDED_FRAME_SAMPLES, 0.3)
	var valid: PackedByteArray = Codec.encode(source)
	_check(Codec.is_valid_packet(valid), "canonical packet validates")

	var empty := PackedByteArray()
	_expect_rejected(empty, "packet_too_short", "empty packet")
	var short := valid.duplicate()
	short.resize(Codec.HEADER_SIZE - 1)
	_expect_rejected(short, "packet_too_short", "truncated header")

	var bad_magic := valid.duplicate()
	bad_magic[0] ^= 0xff
	_expect_rejected(bad_magic, "bad_magic", "bad magic")
	var bad_version := valid.duplicate()
	bad_version[Codec.OFFSET_VERSION] += 1
	_expect_rejected(bad_version, "unsupported_version", "unknown format version")
	var bad_channels := valid.duplicate()
	bad_channels[Codec.OFFSET_CHANNELS] = 2
	_expect_rejected(bad_channels, "unsupported_channels", "non-mono channel count")
	var bad_rate := valid.duplicate()
	bad_rate[Codec.OFFSET_SAMPLE_RATE] = 0x40
	bad_rate[Codec.OFFSET_SAMPLE_RATE + 1] = 0x1f
	_expect_rejected(bad_rate, "unsupported_sample_rate", "non-16-kHz rate")

	var zero_count := valid.duplicate()
	_write_u16(zero_count, Codec.OFFSET_SAMPLE_COUNT, 0)
	_expect_rejected(zero_count, "invalid_sample_count", "zero sample count")
	var excessive_count := valid.duplicate()
	_write_u16(excessive_count, Codec.OFFSET_SAMPLE_COUNT,
		Codec.MAX_FRAME_SAMPLES + 1)
	_expect_rejected(excessive_count, "invalid_sample_count", "oversized declared frame")
	var bad_index := valid.duplicate()
	bad_index[Codec.OFFSET_STEP_INDEX] = Codec.STEP_TABLE.size()
	_expect_rejected(bad_index, "invalid_step_index", "out-of-range step index")
	var bad_reserved := valid.duplicate()
	bad_reserved[Codec.OFFSET_RESERVED] = 1
	_expect_rejected(bad_reserved, "reserved_bits_set", "nonzero reserved byte")

	var truncated := valid.duplicate()
	truncated.resize(truncated.size() - 1)
	_expect_rejected(truncated, "invalid_packet_length", "truncated payload")
	var trailing := valid.duplicate()
	trailing.append(0)
	_expect_rejected(trailing, "invalid_packet_length", "trailing payload data")
	var bad_padding := valid.duplicate()
	bad_padding[bad_padding.size() - 1] |= 0xf0
	_expect_rejected(bad_padding, "nonzero_padding", "noncanonical padding nibble")

	var oversized := PackedByteArray()
	oversized.resize(Codec.MAX_PACKET_BYTES + 1)
	_expect_rejected(oversized, "packet_too_large", "packet above absolute byte ceiling")


func _voice_tone(frequency: float, amplitude: float, count: int,
		phase: float) -> PackedFloat32Array:
	var samples := PackedFloat32Array()
	samples.resize(count)
	for i in range(count):
		# A weak second formant makes this less forgiving than a single sine while
		# remaining exactly reproducible in a headless test.
		var t := float(i) / float(Codec.SAMPLE_RATE_HZ)
		samples[i] = sin(TAU * frequency * t + phase) * amplitude \
			+ sin(TAU * frequency * 2.37 * t + phase * 0.61) * amplitude * 0.16
	return samples


func _mean_abs_error(expected: PackedFloat32Array,
		actual: PackedFloat32Array) -> float:
	if expected.size() != actual.size() or expected.is_empty():
		return INF
	var total_error := 0.0
	for i in range(expected.size()):
		total_error += absf(expected[i] - actual[i])
	return total_error / float(expected.size())


func _max_abs(samples: PackedFloat32Array) -> float:
	var maximum := 0.0
	for sample in samples:
		maximum = maxf(maximum, absf(sample))
	return maximum


func _expect_rejected(packet: PackedByteArray, expected_error: String,
		label: String) -> void:
	var result: Dictionary = Codec.decode(packet)
	_check(not bool(result.ok) and str(result.error) == expected_error \
		and result.samples.is_empty() and not Codec.is_valid_packet(packet),
		"rejects %s (%s)" % [label, expected_error])


func _write_u16(packet: PackedByteArray, offset: int, value: int) -> void:
	packet[offset] = value & 0xff
	packet[offset + 1] = (value >> 8) & 0xff


func _check(condition: bool, label: String) -> void:
	total += 1
	if condition:
		passed += 1
		print("  [ok] " + label)
	else:
		print("  [FAIL] " + label)
