extends Node
## Sfx (autoload) — all audio synthesized at boot (no asset files):
## chirpy monkey blips, thuds, whooshes, a looping wind bed for speed.

const RATE := 22050

var streams: Dictionary = {}
var _pool: Array = []
var _pi := 0
var _pool_3d: Array = []
var _pi_3d := 0


func _ready() -> void:
	streams["jump"] = _tone(300, 560, 0.12, 0.4)
	streams["djump"] = _tone(430, 760, 0.13, 0.4)
	streams["grab"] = _tone(170, 110, 0.09, 0.5)
	streams["land"] = _tone(110, 60, 0.1, 0.45)
	streams["thud"] = _tone(80, 45, 0.16, 0.6)
	streams["banana"] = _seq([_tone(660, 660, 0.07, 0.35), _tone(880, 880, 0.09, 0.35)])
	streams["ook"] = _seq([_tone(950, 700, 0.08, 0.4), _tone(820, 580, 0.08, 0.4), _tone(660, 430, 0.1, 0.4)])
	streams["whoosh"] = _noise_burst(0.3, 0.4, 1400.0)
	streams["roll"] = _noise_burst(0.2, 0.3, 600.0)
	streams["gallop_step"] = _ground_thump(0.105, 0.23)
	# Layered filtered noise plus a short descending bubble tone gives water
	# impacts a body, slap and airy spray component without imported assets.
	streams["water_entry"] = _water_splash(0.46, 0.52, 430.0, 5200.0, 190.0)
	streams["water_exit"] = _water_splash(0.31, 0.36, 560.0, 4300.0, 250.0)
	streams["swim_stroke"] = _water_splash(0.18, 0.24, 720.0, 6100.0, 330.0)
	streams["water_foam"] = _water_splash(0.12, 0.13, 980.0, 7200.0, 410.0)
	streams["water_loop"] = _water_loop()
	# Preserve the original public name used by movement code.
	streams["splash"] = streams["water_entry"]
	streams["gunshot"] = _seq([
		_noise_burst(0.075, 0.92, 5200.0),
		_tone(155, 72, 0.12, 0.42),
	])
	streams["shotgun"] = _seq([
		_noise_burst(0.13, 1.0, 4200.0),
		_tone(105, 48, 0.19, 0.58),
	])
	streams["smg"] = _seq([
		_noise_burst(0.045, 0.74, 6500.0),
		_tone(220, 105, 0.055, 0.30),
	])
	# A long, high-energy rifle report with two reflected arrivals and a diffuse
	# tail. Keeping the reflections inside the sample makes reverb/echo identical
	# in solo and network play without depending on a scene-specific audio bus.
	streams["sniper"] = _sniper_report()
	streams["sniper_bolt"] = _seq([
		_tone(920, 510, 0.035, 0.20),
		_noise_burst(0.055, 0.27, 2600.0),
		_tone(430, 690, 0.045, 0.17),
	])
	streams["sniper_reload"] = _seq([
		_tone(410, 250, 0.075, 0.22),
		_noise_burst(0.070, 0.22, 1700.0),
		_tone(720, 470, 0.065, 0.20),
	])
	streams["shotgun_pump"] = _seq([
		_noise_burst(0.055, 0.30, 1800.0),
		_tone(240, 125, 0.07, 0.25),
	])
	streams["shotgun_reload"] = _tone(340, 210, 0.07, 0.22)
	streams["shotgun_shell"] = _seq([
		_tone(680, 430, 0.035, 0.18),
		_tone(300, 190, 0.045, 0.16),
	])
	streams["weapon_switch"] = _tone(420, 610, 0.055, 0.16)
	streams["melee_swing"] = _seq([
		_noise_burst(0.09, 0.24, 1700.0),
		_tone(190, 95, 0.07, 0.18),
	])
	streams["melee_hit"] = _seq([
		_noise_burst(0.095, 0.52, 1100.0),
		_tone(115, 52, 0.12, 0.34),
	])
	streams["reload"] = _seq([
		_tone(820, 540, 0.055, 0.24),
		_tone(610, 760, 0.06, 0.22),
		_tone(700, 460, 0.055, 0.20),
	])
	streams["reload_done"] = _seq([
		_tone(520, 760, 0.055, 0.25),
		_tone(740, 980, 0.045, 0.20),
	])
	# Reload choreography is deliberately granular: animation thresholds trigger
	# individual foley layers, keeping large-frame skips and future weapons just
	# as punchy as the current four.
	streams["reload_flourish"] = _seq([
		_noise_burst(0.075, 0.18, 2100.0),
		_tone(320, 610, 0.070, 0.20),
	])
	streams["mag_release"] = _seq([
		_tone(1180, 720, 0.025, 0.21),
		_noise_burst(0.030, 0.20, 3400.0),
	])
	streams["mag_toss"] = _seq([
		_noise_burst(0.090, 0.15, 2500.0),
		_tone(410, 680, 0.065, 0.12),
	])
	streams["banana_toss"] = _seq([
		_noise_burst(0.10, 0.13, 1900.0),
		_tone(520, 910, 0.09, 0.19),
	])
	streams["mag_catch"] = _seq([
		_tone(980, 620, 0.030, 0.24),
		_tone(720, 1060, 0.038, 0.18),
	])
	streams["mag_insert"] = _seq([
		_noise_burst(0.045, 0.25, 2200.0),
		_tone(370, 190, 0.060, 0.25),
	])
	streams["reload_snap"] = _seq([
		_tone(740, 1150, 0.034, 0.24),
		_tone(1080, 780, 0.038, 0.18),
	])
	streams["charging_handle"] = _seq([
		_noise_burst(0.050, 0.25, 3000.0),
		_tone(460, 260, 0.050, 0.20),
		_tone(540, 820, 0.040, 0.20),
	])
	streams["shell_pickup"] = _tone(610, 440, 0.045, 0.15)
	streams["shell_catch"] = _seq([
		_tone(880, 590, 0.030, 0.18),
		_noise_burst(0.025, 0.13, 2700.0),
	])
	streams["shotgun_cock"] = _seq([
		_noise_burst(0.065, 0.30, 1700.0),
		_tone(205, 105, 0.080, 0.24),
	])
	streams["bolt_open"] = _seq([
		_tone(720, 410, 0.035, 0.20),
		_noise_burst(0.050, 0.22, 2300.0),
	])
	streams["bolt_close"] = _seq([
		_noise_burst(0.040, 0.26, 3200.0),
		_tone(520, 860, 0.045, 0.23),
	])
	streams["casing_tink"] = _seq([
		_tone(2100, 1550, 0.018, 0.13),
		_tone(1380, 1920, 0.022, 0.09),
	])
	streams["shell_tink"] = _seq([
		_tone(920, 540, 0.026, 0.16),
		_noise_burst(0.025, 0.09, 1800.0),
	])
	streams["mag_floor"] = _seq([
		_noise_burst(0.070, 0.28, 1100.0),
		_tone(180, 92, 0.080, 0.20),
	])
	streams["chest_open"] = _seq([
		_tone(310, 170, 0.080, 0.22),
		_noise_burst(0.13, 0.20, 1200.0),
		_tone(620, 980, 0.080, 0.18),
	])
	streams["ammo_pickup"] = _seq([
		_tone(540, 720, 0.045, 0.19),
		_tone(760, 1040, 0.055, 0.20),
	])
	streams["bandage_pickup"] = _seq([
		_noise_burst(0.070, 0.10, 1600.0),
		_tone(660, 900, 0.070, 0.16),
	])
	streams["bandage_unroll"] = _noise_burst(0.18, 0.17, 1350.0)
	streams["bandage_wrap"] = _seq([
		_noise_burst(0.11, 0.15, 1500.0),
		_tone(260, 330, 0.050, 0.08),
	])
	streams["bandage_tear"] = _seq([
		_noise_burst(0.070, 0.31, 5200.0),
		_tone(610, 360, 0.035, 0.11),
	])
	streams["heal_finish"] = _seq([
		_tone(520, 780, 0.075, 0.22),
		_tone(720, 1120, 0.095, 0.20),
	])
	streams["bandage_cancel"] = _noise_burst(0.075, 0.10, 1200.0)
	streams["empty"] = _tone(180, 120, 0.045, 0.28)
	streams["bullet_hit"] = _noise_burst(0.08, 0.38, 2800.0)
	streams["headshot"] = _seq([
		_tone(980, 1380, 0.055, 0.32),
		_tone(1380, 880, 0.075, 0.28),
	])
	streams["target_hit"] = _seq([
		_tone(440, 620, 0.07, 0.30),
		_tone(760, 540, 0.08, 0.24),
	])
	streams["wind"] = _wind_loop()
	for i in range(10):
		var p := AudioStreamPlayer.new()
		p.bus = &"SFX"
		add_child(p)
		_pool.append(p)
	# Reuse spatial players for frequent swim strokes and wake sounds instead of
	# allocating and freeing a Node3D for every hand contact.
	for i in range(16):
		var p := AudioStreamPlayer3D.new()
		p.bus = &"SFX"
		p.max_distance = 60.0
		p.unit_size = 3.0
		add_child(p)
		_pool_3d.append(p)


func play(sname: String, vol_db := 0.0, pitch := 1.0) -> void:
	if not streams.has(sname):
		return
	var p: AudioStreamPlayer = _pool[_pi]
	_pi = (_pi + 1) % _pool.size()
	p.stop()
	p.stream = streams[sname]
	p.volume_db = vol_db
	p.pitch_scale = clampf(pitch, 0.25, 4.0)
	p.play()


func play_at(sname: String, pos: Vector3, vol_db := 0.0, pitch := 1.0,
		max_distance := 60.0) -> void:
	if not streams.has(sname):
		return
	var p: AudioStreamPlayer3D = _pool_3d[_pi_3d]
	_pi_3d = (_pi_3d + 1) % _pool_3d.size()
	p.stop()
	p.global_position = pos
	p.stream = streams[sname]
	p.volume_db = vol_db
	p.pitch_scale = clampf(pitch, 0.25, 4.0)
	p.max_distance = maxf(max_distance, 1.0)
	p.play()


func _wav(data: PackedByteArray, loop := false) -> AudioStreamWAV:
	var st := AudioStreamWAV.new()
	st.format = AudioStreamWAV.FORMAT_16_BITS
	st.mix_rate = RATE
	st.data = data
	if loop:
		st.loop_mode = AudioStreamWAV.LOOP_FORWARD
		st.loop_end = data.size() / 2
	return st


func _tone(f0: float, f1: float, dur: float, vol: float) -> AudioStreamWAV:
	var n := int(dur * RATE)
	var data := PackedByteArray()
	data.resize(n * 2)
	var phase := 0.0
	for i in range(n):
		var t := float(i) / n
		var f := lerpf(f0, f1, t)
		phase += TAU * f / RATE
		var env := (1.0 - t) * (1.0 - t)
		var s := int(clampf(sin(phase) * env * vol, -1.0, 1.0) * 32767.0)
		data.encode_s16(i * 2, s)
	return _wav(data)


func _noise_burst(dur: float, vol: float, lp_hz: float) -> AudioStreamWAV:
	var n := int(dur * RATE)
	var data := PackedByteArray()
	data.resize(n * 2)
	var y := 0.0
	var a := 1.0 - exp(-TAU * lp_hz / RATE)
	for i in range(n):
		var t := float(i) / n
		var x := randf() * 2.0 - 1.0
		y += a * (x - y)
		var env := sin(PI * t)
		var s := int(clampf(y * env * vol * 2.0, -1.0, 1.0) * 32767.0)
		data.encode_s16(i * 2, s)
	return _wav(data)


func _water_splash(dur: float, vol: float, body_hz: float, spray_hz: float,
		bubble_hz: float) -> AudioStreamWAV:
	var n := maxi(int(dur * RATE), 1)
	var data := PackedByteArray()
	data.resize(n * 2)
	var body := 0.0
	var spray := 0.0
	var bubble_phase := 0.0
	var body_a := 1.0 - exp(-TAU * body_hz / RATE)
	var spray_a := 1.0 - exp(-TAU * spray_hz / RATE)
	for i in range(n):
		var t := float(i) / float(n)
		var white := randf() * 2.0 - 1.0
		body += body_a * (white - body)
		spray += spray_a * (white - spray)
		var airy := spray - body
		var attack := minf(t / 0.018, 1.0)
		var decay := pow(maxf(1.0 - t, 0.0), 1.65)
		var slap := exp(-t * 22.0)
		var bubble_frequency := lerpf(bubble_hz, bubble_hz * 0.42, t)
		bubble_phase += TAU * bubble_frequency / RATE
		var bubble := sin(bubble_phase) * pow(maxf(1.0 - t, 0.0), 2.35)
		var sample := (body * (1.36 + slap * 0.72) + airy * 0.32
			+ bubble * 0.16) * attack * decay * vol
		var encoded := int(clampf(sample, -1.0, 1.0) * 32767.0)
		data.encode_s16(i * 2, encoded)
	return _wav(data)


func _ground_thump(dur: float, vol: float) -> AudioStreamWAV:
	var n := maxi(int(dur * RATE), 1)
	var data := PackedByteArray()
	data.resize(n * 2)
	var low_noise := 0.0
	var phase := 0.0
	var filter_a := 1.0 - exp(-TAU * 520.0 / RATE)
	for i in range(n):
		var t := float(i) / float(n)
		low_noise += filter_a * ((randf() * 2.0 - 1.0) - low_noise)
		phase += TAU * lerpf(86.0, 46.0, t) / RATE
		var attack := minf(t / 0.009, 1.0)
		var decay := pow(maxf(1.0 - t, 0.0), 2.7)
		var sample := (sin(phase) * 0.58 + low_noise * 0.66) * attack * decay * vol
		data.encode_s16(i * 2, int(clampf(sample, -1.0, 1.0) * 32767.0))
	return _wav(data)


func _sniper_report() -> AudioStreamWAV:
	var duration := 1.35
	var n := int(duration * RATE)
	var data := PackedByteArray()
	data.resize(n * 2)
	var low_noise := 0.0
	var room_noise := 0.0
	for i in range(n):
		var t := float(i) / RATE
		var white := randf() * 2.0 - 1.0
		low_noise += 0.085 * (white - low_noise)
		room_noise += 0.018 * (white - room_noise)
		var crack := white * exp(-t * 105.0) * 0.92
		var pressure := (sin(TAU * (88.0 * t - 18.0 * t * t)) * 0.74
			+ low_noise * 0.64) * exp(-t * 8.5)
		var echo_one := 0.0
		if t >= 0.165:
			var echo_t := t - 0.165
			echo_one = (sin(TAU * 73.0 * echo_t) * 0.31
				+ low_noise * 0.25) * exp(-echo_t * 15.0)
		var echo_two := 0.0
		if t >= 0.355:
			var echo_t := t - 0.355
			echo_two = (sin(TAU * 61.0 * echo_t) * 0.18
				+ low_noise * 0.16) * exp(-echo_t * 12.0)
		var reverb_attack := smoothstep(0.025, 0.12, t)
		var reverb_tail := room_noise * reverb_attack * exp(-t * 2.65) * 0.54
		var sample := crack + pressure + echo_one + echo_two + reverb_tail
		data.encode_s16(i * 2,
			int(clampf(sample, -1.0, 1.0) * 32767.0))
	return _wav(data)


func _wind_loop() -> AudioStreamWAV:
	var n := int(1.6 * RATE)
	var data := PackedByteArray()
	data.resize(n * 2)
	var y := 0.0
	var b := 0.0
	for i in range(n):
		var x := randf() * 2.0 - 1.0
		b = clampf(b + x * 0.06, -1.0, 1.0) * 0.985
		y += 0.12 * (b - y)
		var s := int(clampf(y * 1.6, -1.0, 1.0) * 32767.0)
		data.encode_s16(i * 2, s)
	return _wav(data, true)


func _water_loop() -> AudioStreamWAV:
	var n := int(2.4 * RATE)
	var data := PackedByteArray()
	data.resize(n * 2)
	var wash := 0.0
	var fizz := 0.0
	for i in range(n):
		var t := float(i) / float(n)
		var white := randf() * 2.0 - 1.0
		wash += 0.018 * (white - wash)
		fizz += 0.16 * (white - fizz)
		# Integer-period envelopes make the perceived lap rhythm meet cleanly at
		# the loop boundary even though its noise bed remains organic.
		var lap := 0.56 + sin(t * TAU * 3.0) * 0.18 \
			+ sin(t * TAU * 7.0 + 1.2) * 0.09
		var sample := (wash * 1.75 + (fizz - wash) * 0.16) * lap * 0.34
		data.encode_s16(i * 2, int(clampf(sample, -1.0, 1.0) * 32767.0))
	return _wav(data, true)


func _seq(parts: Array) -> AudioStreamWAV:
	var data := PackedByteArray()
	for p in parts:
		data.append_array(p.data)
		var gap := PackedByteArray()
		gap.resize(int(0.025 * RATE) * 2)
		data.append_array(gap)
	return _wav(data)


# ---- vehicle sound synthesis ----------------------------------------------
# Engine loops are built lazily on the first vehicle spawn (they are only a
# few hundred milliseconds of synthesis, but boot should not pay for them).
# Loops are made from phase-locked harmonics of the loop base frequency, so
# they repeat seamlessly; "grit" adds a periodic amplitude chew, and noise
# beds get a head/tail crossfade to hide their seam.

var _vehicle_sounds_ready := false


func ensure_vehicle_sounds() -> void:
	if _vehicle_sounds_ready:
		return
	_vehicle_sounds_ready = true
	# Big-single dual-sport thumper: sparse low firing pulses, hard waveshape.
	streams["engine_single"] = _engine_loop(31.5,
		[[1.0, 1.0], [2.0, 0.66], [3.0, 0.40], [4.0, 0.26], [6.0, 0.13]],
		0.55, 0.46, 0.55, 2.6)
	# Straight-six safari truck: smoother, denser harmonic stack.
	streams["engine_i6"] = _engine_loop(118.0,
		[[0.5, 0.42], [1.0, 1.0], [1.5, 0.22], [2.0, 0.52], [3.0, 0.30],
			[4.0, 0.14]],
		0.42, 0.36, 0.26, 1.7)
	# Airboat: aircraft flat-six drone plus a dominant two-blade prop chop.
	streams["engine_prop"] = _engine_loop(79.0,
		[[0.5, 0.55], [1.0, 1.0], [2.0, 0.62], [3.0, 0.24], [5.0, 0.10]],
		0.46, 0.40, 0.62, 1.9)
	# Turbine core: broadband intake hiss with two locked whine partials.
	streams["jet_turbine"] = _turbine_loop(0.5, 0.34, 1900.0,
		[[1520.0, 0.16], [2280.0, 0.10]])
	# Afterburner: heavy low rumble bed, almost no tone.
	streams["jet_burner"] = _turbine_loop(0.55, 0.55, 240.0,
		[[96.0, 0.20]])
	streams["gear_clunk"] = _seq([_noise_burst(0.028, 0.5, 950.0),
		_tone(220.0, 130.0, 0.07, 0.42)])
	streams["stall_beep"] = _tone(1180.0, 1180.0, 0.16, 0.5)
	streams["touchdown"] = _seq([_noise_burst(0.05, 0.62, 1400.0),
		_ground_thump(0.16, 0.5)])


func _engine_loop(f0: float, harmonics: Array, dur: float, vol: float,
		grit: float, drive: float) -> AudioStreamWAV:
	# All partials are integer multiples of base = f0/2, and the loop holds an
	# integer number of base cycles, so the seam is mathematically silent.
	var base := f0 * 0.5
	var cycles := maxi(int(round(dur * base)), 1)
	var n := int(round(float(cycles) / base * RATE))
	var data := PackedByteArray()
	data.resize(n * 2)
	var phases: Array[float] = []
	for h in harmonics:
		phases.append(fmod(float(h[0]) * 12.9898, TAU))
	for i in range(n):
		var t := float(i) / RATE
		var s := 0.0
		for k in range(harmonics.size()):
			var h: Array = harmonics[k]
			s += float(h[1]) * sin(TAU * float(h[0]) * 2.0 * base * t
				+ phases[k])
		# Soft-clip waveshaping gives combustion growl without aliasing hash.
		s = s * drive / (1.0 + absf(s * drive))
		var chew := 1.0 + grit * 0.5 * (sin(TAU * base * t) - 1.0) * 0.5
		data.encode_s16(i * 2, int(clampf(s * chew * vol, -1.0, 1.0) * 32767.0))
	return _wav(data, true)


func _turbine_loop(dur: float, vol: float, lp_hz: float,
		whines: Array) -> AudioStreamWAV:
	var n := int(dur * RATE)
	var fade := int(0.06 * RATE)
	var raw: Array[float] = []
	raw.resize(n + fade)
	var y := 0.0
	var a := 1.0 - exp(-TAU * lp_hz / RATE)
	for i in range(n + fade):
		y += a * ((randf() * 2.0 - 1.0) - y)
		raw[i] = y
	var data := PackedByteArray()
	data.resize(n * 2)
	var loop_base := 1.0 / dur
	for i in range(n):
		var s := raw[i]
		# Crossfade the tail's extra noise over the head to hide the seam.
		if i < fade:
			var mix := float(i) / float(fade)
			s = raw[n + i] * (1.0 - mix) + raw[i] * mix
		var t := float(i) / RATE
		for w in whines:
			# Lock each whine to an exact multiple of the loop rate.
			var f: float = round(float(w[0]) / loop_base) * loop_base
			s += float(w[1]) * sin(TAU * f * t)
		data.encode_s16(i * 2, int(clampf(s * vol * 2.2, -1.0, 1.0) * 32767.0))
	return _wav(data, true)
