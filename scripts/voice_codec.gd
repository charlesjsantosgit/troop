class_name VoiceCodec
extends RefCounted
## Dependency-free IMA ADPCM for short push-to-talk voice frames.
##
## Samples are 16 kHz mono normalized floats. Every packet carries its own
## predictor and step index, so packet loss cannot corrupt a later frame. The
## envelope is intentionally strict and bounded before any payload is decoded.

const SAMPLE_RATE_HZ := 16000
const CHANNELS := 1
const RECOMMENDED_FRAME_SAMPLES := 320 # 20 ms at 16 kHz.
const MAX_FRAME_SAMPLES := 640 # At most 40 ms in one network packet.

const MAGIC_0 := 0x54 # T
const MAGIC_1 := 0x56 # V
const MAGIC_2 := 0x4f # O
const MAGIC_3 := 0x43 # C
const FORMAT_VERSION := 1

# TVOC + version + channels + sample rate + sample count + predictor + index + reserved.
const HEADER_SIZE := 14
const MAX_PACKET_BYTES := 334 # HEADER_SIZE + ceil((MAX_FRAME_SAMPLES - 1) / 2).

const OFFSET_VERSION := 4
const OFFSET_CHANNELS := 5
const OFFSET_SAMPLE_RATE := 6
const OFFSET_SAMPLE_COUNT := 8
const OFFSET_PREDICTOR := 10
const OFFSET_STEP_INDEX := 12
const OFFSET_RESERVED := 13

const STEP_TABLE := [
	7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31,
	34, 37, 41, 45, 50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130, 143,
	157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449, 494, 544,
	598, 658, 724, 796, 876, 963, 1060, 1166, 1282, 1411, 1552, 1707,
	1878, 2066, 2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871,
	5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635,
	13899, 15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767,
]

const INDEX_TABLE := [
	-1, -1, -1, -1, 2, 4, 6, 8,
	-1, -1, -1, -1, 2, 4, 6, 8,
]


## Encode normalized mono floats. Invalid sizes or non-finite samples return an
## empty byte array; finite values outside -1..1 are safely clipped to PCM16.
static func encode(samples: PackedFloat32Array) -> PackedByteArray:
	if samples.is_empty() or samples.size() > MAX_FRAME_SAMPLES:
		return PackedByteArray()
	var pcm := PackedInt32Array()
	pcm.resize(samples.size())
	for i in range(samples.size()):
		var sample := float(samples[i])
		if is_nan(sample) or is_inf(sample):
			return PackedByteArray()
		sample = clampf(sample, -1.0, 1.0)
		pcm[i] = -32768 if sample <= -1.0 else roundi(sample * 32767.0)
	return encode_pcm16(pcm)


## PCM16-oriented entry point used by deterministic tests and capture adapters.
## Values must already be in the signed 16-bit range.
static func encode_pcm16(samples: PackedInt32Array) -> PackedByteArray:
	var sample_count := samples.size()
	if sample_count < 1 or sample_count > MAX_FRAME_SAMPLES:
		return PackedByteArray()
	for sample in samples:
		if sample < -32768 or sample > 32767:
			return PackedByteArray()

	var predictor := int(samples[0])
	var step_index := _estimate_step_index(samples)
	var packet := PackedByteArray([
		MAGIC_0, MAGIC_1, MAGIC_2, MAGIC_3,
		FORMAT_VERSION, CHANNELS,
		SAMPLE_RATE_HZ & 0xff, (SAMPLE_RATE_HZ >> 8) & 0xff,
		sample_count & 0xff, (sample_count >> 8) & 0xff,
		predictor & 0xff, (predictor >> 8) & 0xff,
		step_index, 0,
	])

	var pending_nibble := -1
	for i in range(1, sample_count):
		var step := int(STEP_TABLE[step_index])
		var difference := int(samples[i]) - predictor
		var code := 0
		if difference < 0:
			code = 8
			difference = -difference

		var reconstructed_delta := step >> 3
		if difference >= step:
			code |= 4
			difference -= step
			reconstructed_delta += step
		var half_step := step >> 1
		if difference >= half_step:
			code |= 2
			difference -= half_step
			reconstructed_delta += half_step
		var quarter_step := step >> 2
		if difference >= quarter_step:
			code |= 1
			reconstructed_delta += quarter_step

		predictor += -reconstructed_delta if (code & 8) != 0 \
			else reconstructed_delta
		predictor = clampi(predictor, -32768, 32767)
		step_index = clampi(step_index + int(INDEX_TABLE[code]), 0,
			STEP_TABLE.size() - 1)

		if pending_nibble < 0:
			pending_nibble = code
		else:
			packet.append(pending_nibble | (code << 4))
			pending_nibble = -1
	if pending_nibble >= 0:
		# The unused high nibble is canonical zero and validated by the decoder.
		packet.append(pending_nibble)

	if packet.size() > MAX_PACKET_BYTES:
		return PackedByteArray()
	return packet


## Decode normalized mono floats. The returned dictionary always contains
## `ok`, `error`, and `samples`; malformed input never produces partial audio.
static func decode(packet: PackedByteArray) -> Dictionary:
	var pcm_result := decode_pcm16(packet)
	if not bool(pcm_result.ok):
		return {
			"ok": false,
			"error": str(pcm_result.error),
			"samples": PackedFloat32Array(),
			"sample_rate": SAMPLE_RATE_HZ,
			"channels": CHANNELS,
		}
	var pcm: PackedInt32Array = pcm_result.samples
	var samples := PackedFloat32Array()
	samples.resize(pcm.size())
	for i in range(pcm.size()):
		var value := int(pcm[i])
		samples[i] = float(value) / (32768.0 if value < 0 else 32767.0)
	return {
		"ok": true,
		"error": "",
		"samples": samples,
		"sample_rate": SAMPLE_RATE_HZ,
		"channels": CHANNELS,
	}


## Decode to signed PCM16 integers. Header fields, exact payload length, index,
## reserved byte, and canonical padding are all checked before decoding.
static func decode_pcm16(packet: PackedByteArray) -> Dictionary:
	if packet.size() < HEADER_SIZE:
		return _invalid_pcm("packet_too_short")
	if packet.size() > MAX_PACKET_BYTES:
		return _invalid_pcm("packet_too_large")
	if packet[0] != MAGIC_0 or packet[1] != MAGIC_1 \
			or packet[2] != MAGIC_2 or packet[3] != MAGIC_3:
		return _invalid_pcm("bad_magic")
	if packet[OFFSET_VERSION] != FORMAT_VERSION:
		return _invalid_pcm("unsupported_version")
	if packet[OFFSET_CHANNELS] != CHANNELS:
		return _invalid_pcm("unsupported_channels")
	if _read_u16(packet, OFFSET_SAMPLE_RATE) != SAMPLE_RATE_HZ:
		return _invalid_pcm("unsupported_sample_rate")

	var sample_count := _read_u16(packet, OFFSET_SAMPLE_COUNT)
	if sample_count < 1 or sample_count > MAX_FRAME_SAMPLES:
		return _invalid_pcm("invalid_sample_count")
	var nibble_count := sample_count - 1
	var payload_bytes := (nibble_count + 1) >> 1
	var expected_size := HEADER_SIZE + payload_bytes
	if packet.size() != expected_size:
		return _invalid_pcm("invalid_packet_length")

	var step_index := int(packet[OFFSET_STEP_INDEX])
	if step_index < 0 or step_index >= STEP_TABLE.size():
		return _invalid_pcm("invalid_step_index")
	if packet[OFFSET_RESERVED] != 0:
		return _invalid_pcm("reserved_bits_set")
	if (nibble_count & 1) != 0 \
			and (packet[packet.size() - 1] & 0xf0) != 0:
		return _invalid_pcm("nonzero_padding")

	var predictor := _read_i16(packet, OFFSET_PREDICTOR)
	var samples := PackedInt32Array()
	samples.resize(sample_count)
	samples[0] = predictor
	for nibble_index in range(nibble_count):
		var packed_byte := int(packet[HEADER_SIZE + (nibble_index >> 1)])
		var code := (packed_byte & 0x0f) if (nibble_index & 1) == 0 \
			else ((packed_byte >> 4) & 0x0f)
		var step := int(STEP_TABLE[step_index])
		var reconstructed_delta := step >> 3
		if (code & 4) != 0:
			reconstructed_delta += step
		if (code & 2) != 0:
			reconstructed_delta += step >> 1
		if (code & 1) != 0:
			reconstructed_delta += step >> 2
		predictor += -reconstructed_delta if (code & 8) != 0 \
			else reconstructed_delta
		predictor = clampi(predictor, -32768, 32767)
		step_index = clampi(step_index + int(INDEX_TABLE[code]), 0,
			STEP_TABLE.size() - 1)
		samples[nibble_index + 1] = predictor

	return {
		"ok": true,
		"error": "",
		"samples": samples,
		"sample_rate": SAMPLE_RATE_HZ,
		"channels": CHANNELS,
	}


static func is_valid_packet(packet: PackedByteArray) -> bool:
	return bool(decode_pcm16(packet).ok)


static func expected_packet_size(sample_count: int) -> int:
	if sample_count < 1 or sample_count > MAX_FRAME_SAMPLES:
		return -1
	return HEADER_SIZE + (sample_count >> 1)


static func _estimate_step_index(samples: PackedInt32Array) -> int:
	if samples.size() < 2:
		return 0
	var total_delta := 0
	for i in range(1, samples.size()):
		total_delta += absi(int(samples[i]) - int(samples[i - 1]))
	# Starting near twice the mean adjacent delta avoids the slow ramp-up that a
	# fixed zero index would repeat at the start of every independent voice frame.
	var target := maxi(7, roundi(float(total_delta) * 2.0 \
		/ float(samples.size() - 1)))
	var best_index := 0
	var best_error := absi(int(STEP_TABLE[0]) - target)
	for i in range(1, STEP_TABLE.size()):
		var error := absi(int(STEP_TABLE[i]) - target)
		if error < best_error:
			best_error = error
			best_index = i
	return best_index


static func _read_u16(packet: PackedByteArray, offset: int) -> int:
	return int(packet[offset]) | (int(packet[offset + 1]) << 8)


static func _read_i16(packet: PackedByteArray, offset: int) -> int:
	var value := _read_u16(packet, offset)
	return value - 65536 if value >= 32768 else value


static func _invalid_pcm(error: String) -> Dictionary:
	return {
		"ok": false,
		"error": error,
		"samples": PackedInt32Array(),
		"sample_rate": SAMPLE_RATE_HZ,
		"channels": CHANNELS,
	}
