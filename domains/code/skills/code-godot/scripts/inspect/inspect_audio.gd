class_name GodotSkillInspectAudio
extends RefCounted

# Reads an audio file as numbers and a one-line ASCII envelope (see
# core/audio_describe.gd) so a caller that cannot hear can still check that a
# sound exists, is the right length, does not clip, starts and ends where it
# should, loops without a click, and slides in the pitch direction it was
# designed to slide in. The audio twin of inspect_image.
#
# Files are read straight off disk — the RIFF parser for .wav,
# AudioStreamOggVorbis/AudioStreamMP3.load_from_file plus
# AudioStreamPlayback.mix_audio for .ogg/.mp3 — never through load()/
# ResourceLoader, so freshly generated audio works before `--import` has ever run
# and files outside the project work by absolute path.
#
# Describe results are read through _field() (and probed with StringName keys,
# `has(&"...")`) instead of get(<string literal>): the dispatcher derives this
# op's allowed parameter list by scanning the sources for that exact call shape,
# so reading an output key that way would turn every one of them into a silently
# accepted parameter.

var utils_script = preload("../core/utils.gd")
var describe_script = preload("../core/audio_describe.gd")

const AUDIO_EXTENSIONS = ["wav", "ogg", "mp3"]
const IMPORT_ARTEFACT_EXTENSIONS = ["sample", "qoa", "import", "md5"]
const EXPECT_KEYS = ["not_silent", "min_duration", "max_duration", "max_peak_db", "min_rms_db",
    "no_clipping", "sample_rate", "channels", "max_leading_silence_ms", "max_trailing_silence_ms",
    "loopable", "pitch_direction"]
# A wrap-around step bigger than this is the click that makes a "seamless" loop
# tick once a second. -34 dBFS: inaudible under music, obvious as a transient.
const LOOP_SEAM_DEFAULT = 0.02
const PITCH_DIRECTIONS = ["rising", "falling", "flat", "none"]


func execute(params: Dictionary) -> void:
    var output_format := str(params.get("format", "json")).strip_edges().to_lower()
    if output_format != "json" and output_format != "text":
        utils_script.log_error("inspect_audio format must be \"json\" or \"text\"; got: " + output_format)
        return

    var expect_value: Variant = params.get("expect", {})
    if not (expect_value is Dictionary):
        utils_script.log_error("inspect_audio expect must be an object, e.g. {\"not_silent\": true, \"no_clipping\": true}")
        return
    var expect: Dictionary = expect_value
    for key in expect.keys():
        if not (str(key) in EXPECT_KEYS):
            utils_script.log_error("Unknown inspect_audio expect key: %s (supported: %s)" % [str(key), ", ".join(EXPECT_KEYS)])
            return
    if expect.has(&"pitch_direction") and not (str(expect["pitch_direction"]) in PITCH_DIRECTIONS):
        utils_script.log_error("inspect_audio expect.pitch_direction must be one of %s; got: %s" % [
            ", ".join(PITCH_DIRECTIONS), str(expect["pitch_direction"])])
        return

    var options := {
        "envelope": bool(params.get("envelope", true)),
        "envelope_columns": int(params.get("envelope_columns", 48)),
        "silence_threshold_db": float(params.get("silence_threshold_db", -60.0))
    }

    var multi := params.has("audio_paths")
    var targets := _collect_targets(params)
    if targets.is_empty():
        return

    var entries: Array = []
    var all_passed := true
    for target in targets:
        var path := str(target)
        var entry := _describe_file(path, options)
        if entry.is_empty():
            return
        # `audio_path` mirrors inspect_image's `image_path`; `path` is the shorter
        # spelling the audio docs and make_sfx.py/make_music.py reports use. Same
        # value, so a caller can read whichever it already knows.
        entry["path"] = path
        var results: Array = []
        if not _check_expectations(expect, entry, path, results):
            all_passed = false
        entry["expect_results"] = results
        entry["expect_failures"] = _failures(results)
        entry["expect_passed"] = results.is_empty() or _all_passed(results)
        entries.append(entry)

    var payload := {}
    if multi:
        payload["audio_paths"] = targets
        payload["count"] = entries.size()
        payload["files"] = entries
        payload["expect_passed"] = all_passed
        var failures: Array = []
        for entry in entries:
            for failure in _list(entry, "expect_failures"):
                failures.append(failure)
        payload["expect_failures"] = failures
    else:
        payload = entries[0]
    payload["ok"] = all_passed

    if output_format == "text":
        print(_as_text(payload, multi))
    else:
        print(JSON.stringify(payload))


# --- reading ----------------------------------------------------------------

func _describe_file(path: String, options: Dictionary) -> Dictionary:
    var extension := path.get_extension().to_lower()
    if not (extension in AUDIO_EXTENSIONS):
        var hint := ""
        if extension in IMPORT_ARTEFACT_EXTENSIONS:
            hint = " - that is an import artefact (Godot stores imported audio as QOA/IMA-ADPCM), not the source; pass the file it was imported from, for example res://audio/jump.wav"
        utils_script.log_error("inspect_audio audio_path has unsupported extension \"%s\": %s (supported: %s)%s" % [
            extension, path, ", ".join(AUDIO_EXTENSIONS), hint])
        return {}
    var absolute := ProjectSettings.globalize_path(path)
    if not FileAccess.file_exists(absolute):
        utils_script.log_error("Audio file does not exist: %s (project-relative paths resolve against res://; pass an absolute path for files outside the project)" % path)
        return {}
    if extension == "wav":
        return _describe_wav(path, absolute, options)
    return _describe_compressed(path, absolute, extension, options)


func _describe_wav(path: String, absolute: String, options: Dictionary) -> Dictionary:
    var bytes := FileAccess.get_file_as_bytes(absolute)
    if bytes.is_empty():
        utils_script.log_error("Could not read any bytes from %s (empty or unreadable file); re-generate it" % path)
        return {}
    var container: Dictionary = describe_script.decode_wav(bytes)
    if container.has(&"error"):
        utils_script.log_error("inspect_audio could not read %s: %s" % [path, str(_field(container, "error", ""))])
        return {}
    var samples: PackedFloat32Array = container["samples"]
    var measured: Dictionary = describe_script.describe(
        samples, int(container["sample_rate"]), int(container["channels"]), options)
    if measured.has(&"error"):
        utils_script.log_error("inspect_audio could not measure %s: %s" % [path, str(_field(measured, "error", ""))])
        return {}
    var entry := {"audio_path": path, "format": "wav", "codec": container["codec"],
        "bit_depth": container["bit_depth"], "pcm_analysis": true}
    entry.merge(measured)
    entry["loop"] = container["loop"]
    entry["import_loop"] = _import_loop(path)
    return entry


func _describe_compressed(path: String, absolute: String, extension: String, options: Dictionary) -> Dictionary:
    var stream: AudioStream = null
    if extension == "ogg":
        stream = AudioStreamOggVorbis.load_from_file(absolute)
    else:
        stream = AudioStreamMP3.load_from_file(absolute)
    if stream == null:
        utils_script.log_error("inspect_audio could not decode %s as %s; the file may be truncated or mislabelled - re-export it (the engine prints the codec error above)" % [path, extension.to_upper()])
        return {}
    # Never mix a looping stream: mix_audio would run until the frame cap.
    # Typed property access rather than Object.set()/get(): a get() with a string
    # literal would register that name as an accepted parameter of this op
    # (utils.gd::allowed_param_keys scans the sources for that call shape).
    var looping := false
    if stream is AudioStreamOggVorbis:
        var vorbis: AudioStreamOggVorbis = stream
        looping = vorbis.loop
        vorbis.loop = false
    elif stream is AudioStreamMP3:
        var mp3: AudioStreamMP3 = stream
        looping = mp3.loop
        mp3.loop = false

    var bytes := FileAccess.get_file_as_bytes(absolute)
    var header: Dictionary = describe_script.ogg_info(bytes) if extension == "ogg" else describe_script.mp3_info(bytes)
    var length := stream.get_length()
    var mix_rate := AudioServer.get_mix_rate()
    var cap := describe_script.max_frames_for(int(mix_rate))
    var wanted := int(ceil(maxf(length, 0.0) * mix_rate)) + 4096
    var frames: PackedVector2Array = describe_script.decode_stream(stream, mini(cap, wanted))
    if frames.is_empty():
        utils_script.log_error("inspect_audio decoded 0 frames from %s; the stream reports %.3f s but plays nothing - re-export it" % [path, length])
        return {}

    var channels := 2
    if not header.is_empty():
        channels = int(header["channels"])
    elif describe_script.looks_mono(frames):
        channels = 1
    var samples: PackedFloat32Array = describe_script.interleave(frames, channels)
    var analysis_rate := int(mix_rate)
    var measured: Dictionary = describe_script.describe(samples, analysis_rate, channels, options)
    if measured.has(&"error"):
        utils_script.log_error("inspect_audio could not measure %s: %s" % [path, str(_field(measured, "error", ""))])
        return {}

    var entry := {"audio_path": path, "format": extension, "codec": "vorbis" if extension == "ogg" else "mp3",
        "bit_depth": null, "pcm_analysis": true,
        "decoded_via": "AudioStreamPlayback.mix_audio at %d Hz" % analysis_rate}
    entry.merge(measured)
    # The engine reports the true stream length; the mixer's own frame count is a
    # few frames short because of the resampler, so do not pass it off as exact.
    entry["duration_s"] = snappedf(length, 0.000001)
    entry["frames"] = int(round(length * float(analysis_rate)))
    entry["analysis_sample_rate"] = analysis_rate
    if not header.is_empty():
        entry["sample_rate"] = int(header["sample_rate"])
        entry["frames"] = int(round(length * float(int(header["sample_rate"]))))
    else:
        entry["note"] = "the %s header could not be parsed, so sample_rate/channels are the decoder's, not the file's" % extension.to_upper()
    entry["loop"] = {"mode": "forward" if looping else "none",
        "begin": 0, "end": 0, "source": "stream"}
    entry["import_loop"] = _import_loop(path)
    return entry


func _import_loop(path: String) -> Variant:
    # What the game will actually hear: the .import sidecar, not the file. A
    # missing sidecar means the asset has not been imported yet.
    var sidecar := path + ".import"
    if not FileAccess.file_exists(ProjectSettings.globalize_path(sidecar)):
        return null
    var config := ConfigFile.new()
    if config.load(sidecar) != OK:
        return null
    var report := {"import_path": sidecar}
    for key in ["edit/loop_mode", "loop", "loop_offset"]:
        if config.has_section_key("params", key):
            report[key] = config.get_value("params", key)
    if report.has(&"edit/loop_mode"):
        var mode := int(report["edit/loop_mode"])
        report["loop_mode_name"] = ["detect", "disabled", "forward", "ping_pong", "backward"][mode] if mode >= 0 and mode < 5 else "unknown"
    return report


func _collect_targets(params: Dictionary) -> Array:
    if params.has("audio_paths"):
        var raw: Variant = params.get("audio_paths", [])
        if not (raw is Array):
            utils_script.log_error("inspect_audio audio_paths must be an array of file or directory paths")
            return []
        var list: Array = raw
        if list.is_empty():
            utils_script.log_error("inspect_audio audio_paths is empty; pass at least one audio file or a directory of sounds")
            return []
        var targets: Array = []
        for item in list:
            var path := _resolve_path(item)
            if path.is_empty():
                utils_script.log_error("inspect_audio audio_paths entries cannot be empty")
                return []
            if _is_directory(path):
                var found := _audio_in_directory(path)
                if found.is_empty():
                    utils_script.log_error("No audio files in directory %s (looked for %s); check the path or list the files explicitly" % [path, ", ".join(AUDIO_EXTENSIONS)])
                    return []
                targets.append_array(found)
            else:
                targets.append(path)
        return targets

    var single := _resolve_path(params.get("audio_path", ""))
    if single.is_empty():
        utils_script.log_error("inspect_audio requires audio_path (a res:// or absolute path to a .wav/.ogg/.mp3), or audio_paths for a list or a directory of sounds")
        return []
    if _is_directory(single):
        utils_script.log_error("audio_path %s is a directory; pass it as audio_paths: [\"%s\"] to describe every sound in it" % [single, single])
        return []
    return [single]


func _audio_in_directory(path: String) -> Array:
    var directory := DirAccess.open(path)
    if directory == null:
        utils_script.log_error("Could not open directory: " + path)
        return []
    var files: Array = []
    for file_name in directory.get_files():
        if str(file_name).get_extension().to_lower() in AUDIO_EXTENSIONS:
            files.append(path.path_join(str(file_name)))
    # step_2.wav must come before step_10.wav, the way a person reads them.
    files.sort_custom(func(left: String, right: String) -> bool:
        return left.get_file().naturalnocasecmp_to(right.get_file()) < 0
    )
    return files


# --- expectations -----------------------------------------------------------

func _check_expectations(expect: Dictionary, entry: Dictionary, path: String, results: Array) -> bool:
    var passed := true
    for key in EXPECT_KEYS:
        if not expect.has(key):
            continue
        var wanted: Variant = expect[key]
        var actual: Variant = null
        var ok := true
        var message := ""
        match key:
            "not_silent":
                actual = not bool(_field(entry, "silent", false))
                ok = bool(actual) == bool(wanted)
                if bool(wanted):
                    message = "every sample is below %s dBFS - nothing was synthesized; check that the generator wrote this file and that its envelope is not all zeroes" % str(_field(entry, "silence_threshold_db", -60.0))
                else:
                    message = "expected silence, but the file has audio"
            "min_duration":
                actual = float(_field(entry, "duration_s", 0.0))
                ok = float(actual) >= float(wanted)
                message = "the file is %s s long, at least %s s expected - the envelope is shorter than the preset's bounds, or the wrong file was written" % [actual, wanted]
            "max_duration":
                actual = float(_field(entry, "duration_s", 0.0))
                ok = float(actual) <= float(wanted)
                message = "the file is %s s long, at most %s s expected - shorten the envelope (attack/decay/sustain/release) or raise max_duration" % [actual, wanted]
            "max_peak_db":
                actual = float(_field(entry, "peak_db", 0.0))
                ok = float(actual) <= float(wanted)
                message = "peak is %s dBFS, at most %s expected - lower --volume or --peak-db when generating" % [actual, wanted]
            "min_rms_db":
                actual = float(_field(entry, "rms_db", -144.0))
                ok = float(actual) >= float(wanted)
                message = "average level is %s dBFS, at least %s expected - the sound is mostly silence; shorten the tail or raise the sustain" % [actual, wanted]
            "no_clipping":
                actual = float(_field(entry, "clipping_ratio", 0.0)) <= 0.0
                ok = bool(actual) == bool(wanted)
                message = "%s of the samples sit at full scale - the mix is clipped; normalise to -1 dBFS (make_sfx.py --peak-db -1)" % str(_field(entry, "clipping_ratio", 0.0))
            "sample_rate":
                actual = int(_field(entry, "sample_rate", 0))
                ok = int(actual) == int(wanted)
                message = "the file is %s Hz, %s expected - regenerate it with --sample-rate %s" % [actual, wanted, wanted]
            "channels":
                actual = int(_field(entry, "channels", 0))
                ok = int(actual) == int(wanted)
                message = "the file has %s channel(s), %s expected - regenerate it with (or without) --stereo" % [actual, wanted]
            "max_leading_silence_ms":
                actual = float(_field(entry, "leading_silence_ms", 0.0))
                ok = float(actual) <= float(wanted)
                message = "the sound starts %s ms in, at most %s ms allowed - trim the leading silence, or the effect will feel laggy" % [actual, wanted]
            "max_trailing_silence_ms":
                actual = float(_field(entry, "trailing_silence_ms", 0.0))
                ok = float(actual) <= float(wanted)
                message = "the sound ends %s ms before the file does, at most %s ms allowed - trim the tail" % [actual, wanted]
            "loopable":
                # true/false gates on the default threshold; a number IS the threshold.
                var limit := LOOP_SEAM_DEFAULT
                if not (wanted is bool) and (wanted is float or wanted is int):
                    limit = float(wanted)
                actual = float(_field(entry, "loop_seam_delta", 0.0))
                var within := float(actual) <= limit
                ok = (within == bool(wanted)) if wanted is bool else within
                message = "the last sample and the first differ by %s (limit %s), so the loop clicks once per pass - render the tail back into the start (make_music.py does this) or add a short fade" % [actual, limit]
            "pitch_direction":
                actual = str(_field(entry, "pitch_direction", "none"))
                ok = str(actual) == str(wanted)
                message = "the pitch contour reads \"%s\", \"%s\" expected (start %s Hz, end %s Hz, tonality %s) - check freq_start/freq_end or the arpeggio steps; \"none\" means the sound is noise, which has no pitch" % [
                    actual, wanted, str(_field(entry, "pitch_start_hz", null)), str(_field(entry, "pitch_end_hz", null)),
                    str(_field(entry, "tonality", 0.0))]
        results.append({"check": key, "expected": wanted, "actual": actual, "passed": ok})
        if not ok:
            passed = false
            utils_script.log_error("inspect_audio expect.%s failed for %s: %s" % [key, path, message])
    return passed


func _failures(results: Array) -> Array:
    var failures: Array = []
    for result in results:
        if not bool(_field(result, "passed", false)):
            failures.append(result)
    return failures


func _all_passed(results: Array) -> bool:
    for result in results:
        if not bool(_field(result, "passed", false)):
            return false
    return true


# --- helpers ----------------------------------------------------------------

func _field(source: Dictionary, key: String, fallback: Variant) -> Variant:
    return source[key] if source.has(key) else fallback


func _list(source: Dictionary, key: String) -> Array:
    var value: Variant = _field(source, key, [])
    return value if value is Array else []


func _resolve_path(raw: Variant) -> String:
    var path := str(raw).strip_edges().replace("\\", "/")
    if path.is_empty():
        return ""
    if path.begins_with("res://") or path.begins_with("user://") or path.begins_with("/"):
        return path
    return "res://" + path


func _is_directory(path: String) -> bool:
    return DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(path))


func _as_text(payload: Dictionary, multi: bool) -> String:
    var lines: PackedStringArray = []
    if multi:
        lines.append("files: %d" % int(_field(payload, "count", 0)))
        for entry in _list(payload, "files"):
            lines.append("")
            lines.append_array(_entry_text(entry))
    else:
        lines.append_array(_entry_text(payload))
    return "\n".join(lines)


func _entry_text(entry: Dictionary) -> PackedStringArray:
    var lines: PackedStringArray = []
    lines.append("audio_path: " + str(_field(entry, "audio_path", "")))
    var depth: Variant = _field(entry, "bit_depth", null)
    lines.append("format: %s (%s, %s)" % [str(_field(entry, "format", "")), str(_field(entry, "codec", "")),
        ("%d-bit" % int(depth)) if depth != null else "compressed"])
    lines.append("duration_s: %s" % float(_field(entry, "duration_s", 0.0)))
    lines.append("sample_rate: %d Hz, channels: %d, frames: %d" % [
        int(_field(entry, "sample_rate", 0)), int(_field(entry, "channels", 0)), int(_field(entry, "frames", 0))])
    lines.append("peak_db: %s  rms_db: %s  dc_offset: %s" % [
        float(_field(entry, "peak_db", 0.0)), float(_field(entry, "rms_db", 0.0)), float(_field(entry, "dc_offset", 0.0))])
    lines.append("silent: %s  clipping_ratio: %s" % [
        str(bool(_field(entry, "silent", false))).to_lower(), float(_field(entry, "clipping_ratio", 0.0))])
    lines.append("leading_silence_ms: %s  trailing_silence_ms: %s" % [
        float(_field(entry, "leading_silence_ms", 0.0)), float(_field(entry, "trailing_silence_ms", 0.0))])
    lines.append("loop_seam_delta: %s" % float(_field(entry, "loop_seam_delta", 0.0)))
    var dominant: Variant = _field(entry, "dominant_frequency_hz", null)
    lines.append("dominant_frequency_hz: %s (%s %s -> %s, tonality %s)" % [
        "none (noise)" if dominant == null else str(dominant),
        str(_field(entry, "pitch_direction", "none")),
        _hz_text(_field(entry, "pitch_start_hz", null)), _hz_text(_field(entry, "pitch_end_hz", null)),
        str(_field(entry, "tonality", 0.0))])
    var loop_value: Variant = _field(entry, "loop", null)
    if loop_value is Dictionary:
        var loop: Dictionary = loop_value
        lines.append("loop: mode=%s begin=%s end=%s source=%s" % [
            str(_field(loop, "mode", "none")), str(_field(loop, "begin", 0)),
            str(_field(loop, "end", 0)), str(_field(loop, "source", "none"))])
    var import_loop: Variant = _field(entry, "import_loop", null)
    if import_loop is Dictionary:
        lines.append("import_loop: " + JSON.stringify(import_loop))
    else:
        lines.append("import_loop: none (no .import sidecar yet - run godot --headless --path <project> --import)")
    if entry.has(&"note"):
        lines.append("note: " + str(_field(entry, "note", "")))
    if entry.has(&"envelope"):
        lines.append("envelope: |" + str(_field(entry, "envelope", "")) + "|")
    for result in _list(entry, "expect_results"):
        lines.append(_expect_line(result))
    return lines


func _hz_text(value: Variant) -> String:
    return "none" if value == null else str(value)


func _expect_line(result: Dictionary) -> String:
    return "expect.%s: %s (expected %s, actual %s)" % [
        str(_field(result, "check", "")),
        "PASS" if bool(_field(result, "passed", false)) else "FAIL",
        str(_field(result, "expected", "")),
        str(_field(result, "actual", ""))
    ]
