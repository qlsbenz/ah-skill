class_name GodotSkillAudioDescribe
extends RefCounted

# Turns audio samples into numbers and one line of ASCII, so a caller that cannot
# hear can still verify that a sound exists, is the right length, does not clip,
# does not click at a loop seam, and moves in the pitch direction it was designed
# to move in.
#
# Pure by design, exactly like core/image_describe.gd: it never logs, never
# touches the filesystem and needs no audio device, so it runs under --headless
# with the Dummy audio driver. Callers own the IO and the error reporting.
#
# Three decoders live here:
#   * `decode_wav` parses the RIFF container itself. That is deliberate:
#     AudioStreamWAV.load_from_file REFUSES 24-bit WAV ("Format not supported for
#     WAVE file (not PCM)") and silently converts 32-bit float down to 16-bit, so
#     going through the engine would lose exactly the facts this op reports.
#   * `decode_stream` mixes an AudioStream (Ogg Vorbis / MP3) through
#     AudioStreamPlayback.mix_audio, which is sample-exact and works headless.
#   * `ogg_info` / `mp3_info` read the codec's own header for the true sample
#     rate and channel count, which the engine's resource does not expose.
#
# Only `options` is read with get(<string literal>). Every other dictionary is
# read with dict[key]: utils.gd::allowed_param_keys derives the op's accepted
# parameter list by scanning the sources for exactly that call shape, so reading
# an output key that way would turn it into a silently accepted parameter of
# inspect_audio. (Which is also why this paragraph spells no key out.)

const SILENCE_THRESHOLD_DB = -60.0
const ENVELOPE_RAMP = " .:-=+*#%@"
const DEFAULT_ENVELOPE_COLUMNS = 48
const MIN_ENVELOPE_COLUMNS = 8
const MAX_ENVELOPE_COLUMNS = 240
# The envelope ramp spans this many dB, so a decay is visible instead of
# collapsing into one character the moment it drops below half amplitude.
const ENVELOPE_FLOOR_DB = -60.0
# 16-bit full scale is 32767/32768; anything at or past it is a sample the
# converter had to clamp.
const CLIP_LEVEL = 0.99995
const PITCH_MIN_HZ = 40.0
const PITCH_MAX_HZ = 6000.0
const PITCH_MIN_WINDOW = 1024
const PITCH_MAX_WINDOW = 4096
# `tonality` is 1 - YIN aperiodicity: 1.0 is a perfectly periodic waveform, 0.0
# is noise. Measured on the make_sfx presets: tones and squares land at
# 0.74-1.00, white and low-passed noise at 0.05-0.39, so 0.60 separates them
# with a wide margin. Below it there is no pitch to report, and the op says so
# with null rather than inventing a number.
const TONALITY_MIN = 0.60
const PITCH_FLAT_RATIO = 1.06
# Pitch is measured on a decimated copy; ~11 kHz keeps every musical fundamental
# and cuts the correlation loop by a factor of four.
const PITCH_WORK_RATE = 11025.0
# YIN's absolute threshold: the FIRST dip below it wins, not the deepest one.
# That is what stops a perfectly periodic waveform from being reported an octave
# too low, because twice the period always correlates at least as well.
const YIN_THRESHOLD = 0.15
# Harmonic correction: after the comb finds the loudest partial, the search drops
# to f/2, f/3 ... and keeps the lowest one still carrying this share of the peak.
# A 25% pulse wave can have a second harmonic louder than its first, and a
# periodic wave has NO energy below its fundamental, so this can pull an answer
# down to the true note but never invent a subharmonic.
const HARMONIC_SHARE = 0.55
const HARMONIC_MAX_DIVISOR = 5
# Measuring more than this costs seconds and answers nothing new; the tail of a
# long track is still covered because the windows are placed by fraction.
const MAX_ANALYSIS_FRAMES = 20 * 48000


# --- WAV container ----------------------------------------------------------

static func decode_wav(bytes: PackedByteArray) -> Dictionary:
    # -> {sample_rate, channels, bit_depth, codec, frames, samples, loop} or {error}
    if bytes.size() < 44:
        return {"error": "file is %d bytes, too short to be a WAV (a header alone is 44)" % bytes.size()}
    if bytes.slice(0, 4).get_string_from_ascii() != "RIFF" or bytes.slice(8, 12).get_string_from_ascii() != "WAVE":
        return {"error": "not a RIFF/WAVE file (the first bytes are not \"RIFF....WAVE\"); re-export it as an uncompressed PCM .wav"}

    var format_tag := -1
    var channels := 0
    var sample_rate := 0
    var bits := 0
    var data_offset := -1
    var data_size := 0
    var loop: Dictionary = {"mode": "none", "begin": 0, "end": 0, "source": "none"}

    var offset := 12
    var total := bytes.size()
    while offset + 8 <= total:
        var chunk_id := bytes.slice(offset, offset + 4).get_string_from_ascii()
        var chunk_size := bytes.decode_u32(offset + 4)
        var body := offset + 8
        if chunk_id == "fmt " and body + 16 <= total:
            format_tag = bytes.decode_u16(body)
            channels = bytes.decode_u16(body + 2)
            sample_rate = bytes.decode_u32(body + 4)
            bits = bytes.decode_u16(body + 14)
            # WAVE_FORMAT_EXTENSIBLE hides the real tag in the GUID's first word.
            if format_tag == 0xFFFE and body + 26 <= total:
                format_tag = bytes.decode_u16(body + 24)
        elif chunk_id == "data":
            data_offset = body
            data_size = mini(int(chunk_size), total - body)
        elif chunk_id == "smpl" and body + 36 <= total:
            var loop_count := bytes.decode_u32(body + 28)
            if loop_count > 0 and body + 36 + 24 <= total:
                var kind := bytes.decode_u32(body + 36 + 4)
                loop = {
                    "mode": ["forward", "ping_pong", "backward"][kind] if kind < 3 else "forward",
                    "begin": int(bytes.decode_u32(body + 36 + 8)),
                    "end": int(bytes.decode_u32(body + 36 + 12)),
                    "source": "smpl"
                }
        offset = body + int(chunk_size) + (int(chunk_size) & 1)
        if chunk_size == 0:
            break

    if format_tag < 0:
        return {"error": "the WAV has no \"fmt \" chunk; re-export it from a tool that writes a standard header"}
    if data_offset < 0:
        return {"error": "the WAV has no \"data\" chunk, so it holds no audio; re-export it"}
    if channels < 1 or channels > 8:
        return {"error": "the WAV header claims %d channels, which is not readable; re-export it as mono or stereo" % channels}
    if sample_rate < 1000 or sample_rate > 384000:
        return {"error": "the WAV header claims a sample rate of %d Hz; re-export it at 44100" % sample_rate}
    if format_tag != 1 and format_tag != 3:
        return {"error": "the WAV is compressed (format tag %d, %s), not PCM, so its samples cannot be measured; re-export it as uncompressed 16-bit PCM" % [
            format_tag, _wav_codec_name(format_tag)]}
    if format_tag == 1 and not (bits == 8 or bits == 16 or bits == 24 or bits == 32):
        return {"error": "unsupported WAV bit depth %d (readable: 8, 16, 24, 32-bit PCM and 32-bit float)" % bits}
    if format_tag == 3 and bits != 32 and bits != 64:
        return {"error": "unsupported WAV float width %d (readable: 32-bit and 64-bit IEEE float)" % bits}

    var bytes_per_sample := bits >> 3
    var frames := floori(float(data_size) / float(bytes_per_sample * channels))
    if frames <= 0:
        return {"error": "the WAV \"data\" chunk is empty, so nothing was recorded; re-export it"}
    var samples := _read_pcm(bytes, data_offset, frames * channels, format_tag, bits)
    return {
        "sample_rate": sample_rate,
        "channels": channels,
        "bit_depth": bits,
        "codec": "pcm_float" if format_tag == 3 else "pcm",
        "frames": frames,
        "samples": samples,
        "loop": loop,
    }


static func _wav_codec_name(tag: int) -> String:
    match tag:
        2: return "MS ADPCM"
        6: return "A-law"
        7: return "mu-law"
        17: return "IMA ADPCM"
        85: return "MP3 in RIFF"
        _: return "unknown codec"


static func _read_pcm(bytes: PackedByteArray, offset: int, count: int, format_tag: int, bits: int) -> PackedFloat32Array:
    var samples := PackedFloat32Array()
    samples.resize(count)
    var cursor := offset
    if format_tag == 3 and bits == 32:
        for index in range(count):
            samples[index] = bytes.decode_float(cursor)
            cursor += 4
    elif format_tag == 3:
        for index in range(count):
            samples[index] = bytes.decode_double(cursor)
            cursor += 8
    elif bits == 8:
        # 8-bit WAV is UNSIGNED with 128 as the zero line — the one PCM width
        # that is not two's complement.
        for index in range(count):
            samples[index] = (bytes.decode_u8(cursor) - 128) / 128.0
            cursor += 1
    elif bits == 16:
        for index in range(count):
            samples[index] = bytes.decode_s16(cursor) / 32768.0
            cursor += 2
    elif bits == 24:
        for index in range(count):
            var value := bytes.decode_u8(cursor) | (bytes.decode_u8(cursor + 1) << 8) | (bytes.decode_u8(cursor + 2) << 16)
            if value >= 0x800000:
                value -= 0x1000000
            samples[index] = value / 8388608.0
            cursor += 3
    else:
        for index in range(count):
            samples[index] = bytes.decode_s32(cursor) / 2147483648.0
            cursor += 4
    return samples


# --- Ogg / MP3 --------------------------------------------------------------

static func ogg_info(bytes: PackedByteArray) -> Dictionary:
    # The Vorbis identification header is the first packet of the first page:
    # 0x01 "vorbis" version:u32 channels:u8 sample_rate:u32
    if bytes.size() < 64 or bytes.slice(0, 4).get_string_from_ascii() != "OggS":
        return {}
    var segments := bytes.decode_u8(26)
    var packet := 27 + segments
    if packet + 16 > bytes.size():
        return {}
    if bytes.decode_u8(packet) != 1 or bytes.slice(packet + 1, packet + 7).get_string_from_ascii() != "vorbis":
        return {}
    return {"channels": int(bytes.decode_u8(packet + 11)), "sample_rate": int(bytes.decode_u32(packet + 12))}


static func mp3_info(bytes: PackedByteArray) -> Dictionary:
    const MPEG_RATES := [[11025, 12000, 8000], [], [22050, 24000, 16000], [44100, 48000, 32000]]
    var start := 0
    if bytes.size() > 10 and bytes.slice(0, 3).get_string_from_ascii() == "ID3":
        var size := (bytes.decode_u8(6) << 21) | (bytes.decode_u8(7) << 14) | (bytes.decode_u8(8) << 7) | bytes.decode_u8(9)
        start = 10 + size
    var limit := mini(bytes.size() - 4, start + 200000)
    var index := start
    while index < limit:
        if bytes.decode_u8(index) == 0xFF and (bytes.decode_u8(index + 1) & 0xE0) == 0xE0:
            var version := (bytes.decode_u8(index + 1) >> 3) & 0x03
            var rate_index := (bytes.decode_u8(index + 2) >> 2) & 0x03
            var mode := (bytes.decode_u8(index + 3) >> 6) & 0x03
            var rates: Array = MPEG_RATES[version]
            if rate_index < 3 and not rates.is_empty():
                return {"channels": 1 if mode == 3 else 2, "sample_rate": int(rates[rate_index])}
        index += 1
    return {}


static func decode_stream(stream: AudioStream, max_frames: int) -> PackedVector2Array:
    # AudioStreamPlayback.mix_audio is exposed to scripting in 4.x and is
    # sample-exact (a full-scale sine reads back as 0.99997), so a compressed
    # stream can be measured without decoding it by hand. Output is always a pair
    # of channels at the AudioServer mix rate, whatever the source rate was.
    var out := PackedVector2Array()
    if stream == null:
        return out
    var playback: AudioStreamPlayback = stream.instantiate_playback()
    if playback == null:
        return out
    playback.start(0.0)
    while out.size() < max_frames:
        var chunk: PackedVector2Array = playback.mix_audio(1.0, mini(4096, max_frames - out.size()))
        if chunk.is_empty():
            break
        out.append_array(chunk)
    playback.stop()
    return out


static func interleave(frames: PackedVector2Array, channels: int) -> PackedFloat32Array:
    var samples := PackedFloat32Array()
    samples.resize(frames.size() * channels)
    var cursor := 0
    if channels == 1:
        for frame in frames:
            samples[cursor] = frame.x
            cursor += 1
    else:
        for frame in frames:
            samples[cursor] = frame.x
            samples[cursor + 1] = frame.y
            cursor += 2
    return samples


static func looks_mono(frames: PackedVector2Array) -> bool:
    for frame in frames:
        if absf(frame.x - frame.y) > 1e-6:
            return false
    return true


# --- measurement ------------------------------------------------------------

static func describe(samples: PackedFloat32Array, sample_rate: int, channels: int, options: Dictionary) -> Dictionary:
    var count := samples.size()
    if count <= 0 or channels <= 0 or sample_rate <= 0:
        return {"error": "no samples to measure"}
    var frames := floori(float(count) / float(channels))
    var threshold_db := float(options.get("silence_threshold_db", SILENCE_THRESHOLD_DB))
    var threshold: float = db_to_linear(threshold_db)  # @GlobalScope helper

    var peak := 0.0
    var energy := 0.0
    var offset := 0.0
    var clipped := 0
    for value in samples:
        var magnitude := absf(value)
        if magnitude > peak:
            peak = magnitude
        if magnitude >= CLIP_LEVEL:
            clipped += 1
        energy += value * value
        offset += value
    var rms := sqrt(energy / count)

    var first := -1
    var last := -1
    for index in range(count):
        if absf(samples[index]) >= threshold:
            first = index
            break
    if first >= 0:
        for index in range(count - 1, -1, -1):
            if absf(samples[index]) >= threshold:
                last = index
                break

    var mono := _to_mono(samples, channels, frames)
    var result := {
        "duration_s": snappedf(float(frames) / float(sample_rate), 0.000001),
        "sample_rate": sample_rate,
        "channels": channels,
        "frames": frames,
        "peak_db": decibels(peak),
        "rms_db": decibels(rms),
        "silent": peak < threshold,
        "clipping_ratio": snappedf(float(clipped) / float(count), 0.000001),
        "dc_offset": snappedf(offset / float(count), 0.000001),
        "silence_threshold_db": threshold_db,
    }
    if first < 0:
        result["leading_silence_ms"] = snappedf(float(frames) / float(sample_rate) * 1000.0, 0.001)
        result["trailing_silence_ms"] = result["leading_silence_ms"]
    else:
        result["leading_silence_ms"] = snappedf(float(_frame_of(first, channels)) / float(sample_rate) * 1000.0, 0.001)
        result["trailing_silence_ms"] = snappedf(
            float(frames - 1 - _frame_of(last, channels)) / float(sample_rate) * 1000.0, 0.001)

    result["loop_seam_delta"] = _seam_delta(samples, channels, frames)
    var pitch := _pitch_contour(mono, sample_rate, _frame_of(first, channels) if first >= 0 else 0,
            _frame_of(last, channels) if last >= 0 else frames - 1)
    result.merge(pitch)
    if bool(options.get("envelope", true)):
        result["envelope"] = envelope_line(mono, int(options.get("envelope_columns", DEFAULT_ENVELOPE_COLUMNS)))
    return result


static func _to_mono(samples: PackedFloat32Array, channels: int, frames: int) -> PackedFloat32Array:
    if channels == 1:
        return samples
    var mono := PackedFloat32Array()
    mono.resize(frames)
    var cursor := 0
    var scale := 1.0 / float(channels)
    for index in range(frames):
        var total := 0.0
        for _channel in range(channels):
            total += samples[cursor]
            cursor += 1
        mono[index] = total * scale
    return mono


static func _seam_delta(samples: PackedFloat32Array, channels: int, frames: int) -> float:
    # What a gapless loop actually plays at the wrap point: the last frame
    # followed by the first one. A step here is the click.
    if frames < 2:
        return 0.0
    var worst := 0.0
    var tail := (frames - 1) * channels
    for channel in range(channels):
        worst = maxf(worst, absf(samples[channel] - samples[tail + channel]))
    return snappedf(worst, 0.000001)


static func envelope_line(mono: PackedFloat32Array, columns: int) -> String:
    var frames := mono.size()
    if frames <= 0:
        return ""
    columns = clampi(columns, MIN_ENVELOPE_COLUMNS, MAX_ENVELOPE_COLUMNS)
    var line := ""
    var last := ENVELOPE_RAMP.length() - 1
    for column in range(columns):
        var start := floori(float(column) * float(frames) / float(columns))
        var stop := maxi(start + 1, floori(float(column + 1) * float(frames) / float(columns)))
        # A long file is sampled inside the slice rather than scanned: 256 probes
        # per column locate the slice peak closely enough for one character.
        var step := maxi(1, floori(float(stop - start) / 256.0))
        var peak := 0.0
        var index := start
        while index < stop:
            var magnitude := absf(mono[index])
            if magnitude > peak:
                peak = magnitude
            index += step
        if peak <= 0.0:
            line += ENVELOPE_RAMP[0]
            continue
        var level := (linear_to_db(peak) - ENVELOPE_FLOOR_DB) / (0.0 - ENVELOPE_FLOOR_DB)  # @GlobalScope helper
        line += ENVELOPE_RAMP[clampi(int(round(level * last)), 0, last)]
    return line


# --- pitch ------------------------------------------------------------------

static func _pitch_contour(mono: PackedFloat32Array, sample_rate: int, first: int, last: int) -> Dictionary:
    var voiced := last - first + 1
    if voiced < PITCH_MIN_WINDOW:
        return {"dominant_frequency_hz": null, "pitch_start_hz": null, "pitch_end_hz": null,
                "pitch_direction": "none", "tonality": 0.0}
    # A fifth of the sounding part, capped: long enough to resolve a bass note,
    # short enough that the start and end windows do not overlap on a 150 ms
    # slide (which would report every sweep as "flat").
    var window := mini(voiced, clampi(floori(float(voiced) / 5.0), PITCH_MIN_WINDOW, PITCH_MAX_WINDOW))
    var span := float(voiced - window)
    var middle := _estimate_pitch(mono, first + floori(span * 0.5), window, sample_rate)
    var start := _estimate_pitch(mono, first + floori(span * 0.15), window, sample_rate)
    var end := _estimate_pitch(mono, first + floori(span * 0.85), window, sample_rate)

    var tonality := float(middle["tonality"])
    var dominant: Variant = middle["hz"] if tonality >= TONALITY_MIN else null
    var start_hz: Variant = start["hz"] if float(start["tonality"]) >= TONALITY_MIN else null
    var end_hz: Variant = end["hz"] if float(end["tonality"]) >= TONALITY_MIN else null
    var direction := "none"
    if start_hz != null and end_hz != null:
        var ratio := float(end_hz) / float(start_hz)
        if ratio > PITCH_FLAT_RATIO:
            direction = "rising"
        elif ratio < 1.0 / PITCH_FLAT_RATIO:
            direction = "falling"
        else:
            direction = "flat"
    return {
        "dominant_frequency_hz": dominant,
        "pitch_start_hz": start_hz,
        "pitch_end_hz": end_hz,
        "pitch_direction": direction,
        "tonality": tonality,
    }


static func _estimate_pitch(mono: PackedFloat32Array, start: int, window: int, sample_rate: int) -> Dictionary:
    # Two measurements of the same slice, each used where it is strong:
    #   * WHERE the pitch is -> Goertzel over a LINEAR frequency comb. A
    #     log-spaced comb is wrong here: the Hann main lobe is a constant
    #     4*rate/N wide, so above ~1 kHz a 1/16-octave comb steps straight over
    #     peaks and reports a harmonic instead of the fundamental (observed: a
    #     1311 Hz square read as 3935 Hz).
    #   * WHETHER there IS a pitch -> YIN aperiodicity. Spectral measures
    #     (peak/mean, concentration) call heavily low-passed noise tonal because
    #     its energy really is concentrated; periodicity does not.
    start = maxi(0, mini(start, mono.size() - window))
    if window < 64 or start < 0:
        return {"hz": 0.0, "tonality": 0.0}
    var windowed := PackedFloat32Array()
    windowed.resize(window)
    var mean := 0.0
    for index in range(window):
        mean += mono[start + index]
    mean /= float(window)
    var step := TAU / float(window - 1)
    for index in range(window):
        # Hann window, with the slice mean removed so a DC offset cannot
        # masquerade as energy in the lowest bins.
        windowed[index] = (mono[start + index] - mean) * (0.5 - 0.5 * cos(step * index))
    return {
        "hz": _spectral_peak(windowed, sample_rate),
        "tonality": float(_periodicity(mono, start, window, sample_rate)["tonality"]),
    }


static func _spectral_peak(windowed: PackedFloat32Array, sample_rate: int) -> float:
    var window := windowed.size()
    var top := minf(PITCH_MAX_HZ, float(sample_rate) * 0.4)
    if top <= PITCH_MIN_HZ or window < 64:
        return 0.0
    # Half the Hann main lobe (4 * rate / N): the comb cannot step over a peak.
    # A log-spaced comb is wrong here - the lobe width is constant in Hz, so
    # above ~1 kHz a 1/16-octave comb steps over peaks and reports a harmonic
    # (observed: a 1311 Hz square read as 3935 Hz).
    var grid := 2.0 * float(sample_rate) / float(window)
    var best := -1.0
    var best_hz := PITCH_MIN_HZ
    var hz := PITCH_MIN_HZ
    while hz <= top:
        var magnitude := _goertzel(windowed, hz, sample_rate)
        if magnitude > best:
            best = magnitude
            best_hz = hz
        hz += grid
    if best <= 0.0:
        return 0.0

    var peak := best
    for divisor in range(2, HARMONIC_MAX_DIVISOR + 1):
        var candidate := best_hz / float(divisor)
        if candidate < PITCH_MIN_HZ:
            break
        var found := _peak_near(windowed, candidate, grid, sample_rate)
        if float(found["magnitude"]) >= HARMONIC_SHARE * peak:
            best_hz = float(found["hz"])
            best = float(found["magnitude"])

    # Three narrowing sweeps around the winner: brings a 440 Hz sine in at
    # 439.8 Hz for a few thousand extra multiplies.
    var half_span := grid
    for _round in range(3):
        var step_hz := half_span / 3.0
        var centre := best_hz
        for probe in range(-3, 4):
            if probe == 0:
                continue
            var candidate := centre + step_hz * float(probe)
            if candidate < 20.0:
                continue
            var magnitude := _goertzel(windowed, candidate, sample_rate)
            if magnitude > best:
                best = magnitude
                best_hz = candidate
        half_span = step_hz
    return snappedf(best_hz, 0.01)


static func _peak_near(windowed: PackedFloat32Array, hz: float, grid: float, sample_rate: int) -> Dictionary:
    var best := -1.0
    var best_hz := hz
    for probe in range(-2, 3):
        var candidate := hz + grid * 0.5 * float(probe)
        if candidate < 20.0:
            continue
        var magnitude := _goertzel(windowed, candidate, sample_rate)
        if magnitude > best:
            best = magnitude
            best_hz = candidate
    return {"hz": best_hz, "magnitude": best}


static func _periodicity(mono: PackedFloat32Array, start: int, window: int, sample_rate: int) -> Dictionary:
    # YIN: the cumulative-mean-normalised difference function. 1.0 minus its
    # chosen value is the "how periodic is this" score, and the lag it chose is a
    # coarse fundamental. A sine or a square scores ~1.0, white noise ~0.1,
    # 450 Hz low-passed noise ~0.05.
    var factor := maxi(1, floori(float(sample_rate) / PITCH_WORK_RATE))
    var count := floori(float(window) / float(factor))
    if count < 128:
        factor = 1
        count = window
        if count < 128:
            return {"tonality": 0.0, "hz": 0.0}
    var decimated := PackedFloat32Array()
    decimated.resize(count)
    var scale := 1.0 / float(factor)
    var cursor := start
    for index in range(count):
        var total := 0.0
        for inner in range(factor):
            total += mono[cursor + inner]
        decimated[index] = total * scale
        cursor += factor

    var rate := float(sample_rate) * scale
    var half := floori(float(count) * 0.5)
    var min_lag := maxi(2, floori(rate / PITCH_MAX_HZ))
    var max_lag := mini(half - 1, floori(rate / PITCH_MIN_HZ))
    if max_lag <= min_lag:
        return {"tonality": 0.0, "hz": 0.0}

    var values := PackedFloat32Array()
    values.resize(max_lag + 1)
    var running := 0.0
    var deepest := min_lag
    var deepest_value := 2.0
    var seen := 0
    for lag in range(min_lag, max_lag + 1):
        var difference := 0.0
        for index in range(half):
            var delta: float = decimated[index] - decimated[index + lag]
            difference += delta * delta
        running += difference
        seen += 1
        var average := running / float(seen)
        var value := difference / average if average > 0.0 else 1.0
        values[lag] = value
        if value < deepest_value:
            deepest_value = value
            deepest = lag

    # First dip below the absolute threshold, walked down to its local minimum.
    # Taking the global minimum instead is the classic octave-down bug: twice the
    # period always matches at least as well as the period.
    var chosen := -1
    var lag := min_lag
    while lag <= max_lag:
        if values[lag] < YIN_THRESHOLD:
            while lag + 1 <= max_lag and values[lag + 1] < values[lag]:
                lag += 1
            chosen = lag
            break
        lag += 1
    if chosen < 0:
        chosen = deepest
    return {
        "tonality": snappedf(clampf(1.0 - values[chosen], 0.0, 1.0), 0.001),
        "hz": rate / float(chosen),
    }


static func _goertzel(windowed: PackedFloat32Array, hz: float, sample_rate: int) -> float:
    var coefficient := 2.0 * cos(TAU * hz / float(sample_rate))
    var s1 := 0.0
    var s2 := 0.0
    for value in windowed:
        var s0 := value + coefficient * s1 - s2
        s2 = s1
        s1 = s0
    return sqrt(maxf(0.0, s1 * s1 + s2 * s2 - coefficient * s1 * s2))


# --- helpers ----------------------------------------------------------------

static func _frame_of(sample_index: int, channels: int) -> int:
    return floori(float(sample_index) / float(channels))


static func decibels(value: float) -> float:
    # NOT named linear_to_db: @GlobalScope already exports linear_to_db(), and an
    # unqualified call inside this class silently resolves to the built-in, so a
    # same-named static here would never run (verified on 4.7 - it cost an hour).
    if value <= 0.0000001:
        return -144.0
    return snappedf(linear_to_db(value), 0.01)


static func max_frames_for(sample_rate: int) -> int:
    return maxi(sample_rate, MAX_ANALYSIS_FRAMES)
