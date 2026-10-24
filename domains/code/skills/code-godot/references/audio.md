# Audio: making sound without a sound source, checking it without ears

Games built by an agent are silent, because the agent has no sample library and cannot hear what it would
have produced. This reference closes that loop with three tools:

| Need | Tool | Verify with |
| --- | --- | --- |
| Sound effects | `scripts/assets/make_sfx.py` (stdlib Python, sfxr-style synthesizer) | `inspect_audio` + the `expect` block the tool prints |
| Background music | `scripts/assets/make_music.py` (stdlib Python, step-sequencer tracker) | `inspect_audio` with `expect.loopable` |
| "Is this file actually a sound?" | dispatcher op `inspect_audio` | its own `expect` gates drive the exit code |

Everything here was run as written against Godot 4.7 on a real project. Nothing needs pip, a network, or an
audio device — the generators are pure Python and `inspect_audio` works under `--headless` with the Dummy
audio driver.

---

## 1. Sound effects — `make_sfx.py`

`--list-presets` prints every preset with its full parameter set; `--preset NAME` renders one; `--variations N`
renders N siblings of it.

```bash
python3 /absolute/path/to/godot/scripts/assets/make_sfx.py --list-presets
python3 /absolute/path/to/godot/scripts/assets/make_sfx.py --preset jump --out /absolute/path/to/project/audio/
python3 /absolute/path/to/godot/scripts/assets/make_sfx.py --preset explosion --seed 7 --variations 3 --out /absolute/path/to/project/audio/
```

Output is one 16-bit PCM mono WAV per file plus a JSON report. Nothing is written unless the whole render
succeeded, and the report carries the same numbers `inspect_audio` will measure:

```json
{"ok": true, "counts": {"files": 1}, "preset": "jump", "seed": 7, "sample_rate": 44100,
 "duration_bounds": [0.08, 0.4], "pitch_direction": "rising", "needs_import": true,
 "files": [{"path": "/absolute/path/to/project/audio/jump.wav", "format": "wav", "duration_s": 0.168277,
            "peak_db": -1.0, "rms_db": -5.07, "dc_offset": -0.002104, "clipping_ratio": 0.0,
            "leading_silence_ms": 0.068, "trailing_silence_ms": 0.136,
            "pitch_start_hz": 179.83, "pitch_end_hz": 639.4, "pitch_direction": "rising",
            "envelope": "@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@%%%%%%%%####**+",
            "expect": {"not_silent": true, "no_clipping": true, "min_duration": 0.08,
                       "max_duration": 0.4, "pitch_direction": "rising"}}]}
```

**Paste `files[0].expect` straight into `inspect_audio`.** That is the whole verification loop: the
synthesizer states what it intended, the inspector measures the file, and the exit code is the answer.

### Presets

Every preset is a set of DSP parameters chosen so the sound *is* what it claims by construction.
`pitch_direction` is what `inspect_audio` measures on the rendered file; it was checked across five seeds,
and the one preset whose contour is not stable (`land`, whose noise sometimes drowns its sub thump) simply
carries no contour gate.

| Preset | What it is | Duration bounds | Measured `pitch_direction` |
| --- | --- | --- | --- |
| `alarm` | Three repeats of a rising two-tone square - warning siren. | 0.40-1.50 s | `falling` |
| `blip` | Flat short square tick - cursor movement, typewriter text. | 0.02-0.15 s | `flat` |
| `cancel` | Falling two-note tone - back / dismiss. Pitch goes DOWN. | 0.10-0.40 s | `falling` |
| `coin` | Two-step rising square arpeggio with a bright held tail. | 0.25-0.70 s | `flat` |
| `confirm` | Rising two-note tone - accept / OK. Pitch goes UP. | 0.10-0.40 s | `rising` |
| `dash` | Noise whoosh: the lowpass opens then closes again. | 0.12-0.60 s | `none` |
| `door` | Slow low saw creak with heavy vibrato - a door or lever. | 0.30-1.10 s | `falling` |
| `error` | Low buzzing falling square, repeated twice - rejected input. | 0.15-0.60 s | `flat` |
| `explosion` | Low-passed noise with punch and a long decay over a dropping sine sub. | 0.50-1.20 s | `none` |
| `footstep` | Tiny filtered noise tap - one step on a hard floor. | 0.02-0.15 s | `none` |
| `hit` | Very short bright noise burst plus a low thump - an impact. | 0.05-0.30 s | `none` |
| `hurt` | Falling gritty square with noise and a low body - taking damage. | 0.10-0.50 s | `falling` |
| `jump` | Rising square slide - short, springy, upward. | 0.08-0.40 s | `rising` |
| `land` | Soft low thump - landing after a fall. | 0.06-0.45 s | not gated |
| `laser` | Falling saw sweep through a closing lowpass - the classic pew. | 0.08-0.40 s | `falling` |
| `pickup` | Two-step rising blip - a small collectible. | 0.08-0.45 s | `rising` |
| `powerup` | Four-step rising arpeggio with vibrato on the held top note. | 0.30-1.00 s | `rising` |
| `select` | Thin flat square click, lower than blip - menu highlight. | 0.02-0.15 s | `flat` |
| `shoot` | Short falling square with a noise edge - a light weapon. | 0.05-0.30 s | `falling` |
| `splash` | Bright noise with a closing lowpass and a long tail - water. | 0.25-0.90 s | `none` |

### Which preset for which event

| Game event | Preset | Note |
| --- | --- | --- |
| Coin / gem / score pickup | `coin`, `pickup` | `coin` is the longer jingle, `pickup` the quick blip |
| Jump, double jump | `jump` | raise `freq_end` for a higher-sounding jump |
| Land, footstep | `land`, `footstep` | `footstep` × 3-4 `--variations` stops the walk cycle sounding mechanical |
| Shoot, laser | `shoot`, `laser` | `laser` is the long sweep, `shoot` the short tick |
| Enemy hit, player hurt | `hit`, `hurt` | `hit` is the impact, `hurt` the "ow" with a falling tone |
| Explosion, death | `explosion` | `--variations` gives every barrel its own boom |
| Power-up, level up, heal | `powerup` | four-step arpeggio; `--duration 0.9` for a bigger moment |
| Menu move / highlight | `blip`, `select` | under 150 ms, so holding a direction does not turn into a drone |
| Accept / cancel / invalid | `confirm`, `cancel`, `error` | up / down / buzz: three unmistakable directions |
| Door, lever, chest | `door` | |
| Dash, swoosh, wind | `dash` | |
| Water, splash, bubble | `splash` | |
| Alarm, warning, timer | `alarm` | |

### Seeds and variations

- `--seed N` fixes everything: the noise **and** a small pitch/decay jitter applied to every render. The same
  seed is byte-identical; a different seed is a sibling of the same sound. `--seed` defaults to `0`.
- `--variations N` writes `name_1.wav … name_N.wav` with a wider jitter (±2 semitones, ±18% envelope, ±0.06
  duty). They differ audibly from each other and stay inside the preset's duration bounds — exactly what a
  footstep or hit needs so repetition does not sound like a machine gun.

### Custom sounds

`--params '{…}'` (or `--params-file FILE`) merges over the preset, or over the defaults when no `--preset`
is given. Start from `--list-presets` output and edit. Unknown keys are rejected with the nearest real name.

```bash
python3 /absolute/path/to/godot/scripts/assets/make_sfx.py --name swoop --out /absolute/path/to/project/audio/ \
  --params '{"wave":"saw","freq_start":200,"freq_end":900,"attack":0.01,"decay":0.05,"sustain":0.1,"release":0.1}'
```

| Group | Keys |
| --- | --- |
| Oscillator | `wave` (`square`/`saw`/`triangle`/`sine`/`noise`), `duty`, `duty_sweep` |
| Pitch | `freq_start`, `freq_end`, `freq_curve` (`exp` musical / `linear`), `vibrato_depth` (semitones), `vibrato_rate` (Hz), `arpeggio` |
| Envelope | `attack`, `decay`, `sustain`, `sustain_level`, `release` (seconds), `punch` |
| Body | `noise_level` (white noise mixed into the oscillator), `sub_level`, `sub_freq_start`, `sub_freq_end`, `sub_decay` (a sine layer underneath — this is what makes an impact land) |
| Filters | `lowpass`, `lowpass_sweep` (cutoff multiplier across the sound), `highpass` |
| Grit | `bitcrush_bits`, `bitcrush_rate` |
| Structure | `repeat` (retrigger the whole sound N times inside the duration) |

`arpeggio` is either a plain list of semitone offsets spread evenly (`[0, 4, 7, 12]`) or explicit steps
(`[{"at": 0.12, "semitones": 5}]`, where `at` is a fraction of the sound).

Other flags: `--duration S` rescales the whole ADSR (it stretches the shape, it does not truncate),
`--volume 0-1` is a linear gain after normalisation, `--peak-db` moves the normalisation target (default
`-1.0`), `--sample-rate`, `--out FILE_OR_DIR`, `--no-overwrite`, `--pretty`.

### What the synthesizer guarantees

- Normalised to −1 dBFS, so nothing clips and every sound sits at the same loudness.
- A 2 ms fade on the first and last samples, so no file can click when it is triggered.
- A DC blocker at 20 Hz, so an asymmetric pulse wave does not waste headroom or thump on trigger.
- Deterministic: same seed, byte-identical file.

---

## 2. Music — `make_music.py`

`--list-presets` prints the full song JSON of every preset; `--song FILE` renders one you wrote yourself
(see *Song JSON* below).

```bash
python3 /absolute/path/to/godot/scripts/assets/make_music.py --list-presets
python3 /absolute/path/to/godot/scripts/assets/make_music.py --preset overworld --out /absolute/path/to/project/audio/
python3 /absolute/path/to/godot/scripts/assets/make_music.py --preset battle --bars 16 --tempo 168 --stereo --out /absolute/path/to/project/audio/
```

| Preset | Tempo | Loop | Tracks | Drums |
| --- | --- | --- | --- | --- |
| `menu` | 88 BPM | 8 bars | pad, lead, bass | hat |
| `overworld` | 124 BPM | 8 bars | lead, harmony, bass | kick, snare, hat |
| `battle` | 168 BPM | 8 bars | lead, stabs, bass | kick, snare, hat, tom |
| `victory` | 140 BPM | 4 bars | fanfare, counter, bass | kick, snare, hat |

`--list-presets` prints each preset's complete song object under `presets.<name>.song`. Save one to a file,
edit the note rows, and re-render — that is the intended authoring loop.

### Song JSON

Write the song to a file and render it with `--song`. `--out` ending in `.wav` names the file; `--out DIR/`
names it after the song instead.

```bash
cat > /absolute/path/to/project/song.json <<'JSON'
{
  "name": "overworld",
  "tempo": 124,
  "steps_per_beat": 4,
  "beats_per_bar": 4,
  "bars": 8,
  "master_volume": 0.9,
  "sample_rate": 44100,
  "tracks": [
    {"name": "lead", "wave": "square", "duty": 0.5, "volume": 0.75, "pan": 0.2, "octave": 0,
     "envelope": {"attack": 0.004, "decay": 0.035, "sustain_level": 0.68, "release": 0.055},
     "notes": "C5 - E5 - G5 - E5 - F5 - E5 - D5 - . -"},
    {"name": "bass", "wave": "triangle", "volume": 0.85,
     "notes": [{"note": "C3", "len": 4}, {"note": "G2", "len": 4}]}
  ],
  "drums": {"volume": 0.8, "kick": "x.......x.......", "snare": "....x.......x...", "hat": "x.x.x.x.x.x.x.x."}
}
JSON
python3 /absolute/path/to/godot/scripts/assets/make_music.py --song /absolute/path/to/project/song.json \
  --out /absolute/path/to/project/audio/theme.wav
```

- **Notes** are whitespace-separated tokens, one per step. A note is `<A-G>[#|b]<octave>`, equal-tempered
  with A4 = 440 Hz (`C4`, `F#3`, `Bb2`). `.` is a rest, `-` holds the previous note one more step, and `+`
  stacks a chord (`C4+E4+G4`). A list form `[{"note": "C3", "len": 4}]` means the same thing.
- **Drum rows** are character strings, one character per step: `x` a hit, `X` an accented hit, `.` a rest.
  Voices: `kick` (pitch-dropping sine), `snare` (band-passed noise + a 185 Hz tone), `hat` (high-passed noise
  burst), `tom`, `clap`. All synthesized, all deterministic.
- **Tiling**: the loop is `bars × beats_per_bar × steps_per_beat` steps long and every pattern is repeated to
  fill it, so a one-bar drum row under a four-bar melody is the normal way to write. Leave `bars` out and the
  loop is the longest pattern rounded up to whole bars. The report says how often each track tiled.
- `--bars`, `--tempo`, `--sample-rate`, `--name` and `--stereo` override the song from the command line.
  `pan` only takes effect with `--stereo`.

### The loop is seamless by construction

The output buffer is exactly one loop long and every note's release tail is written back into the *start* of
the buffer, so the last sample flows into the first. Whatever discontinuity remains is bled away over the
final 2 ms and reported honestly:

```json
{"ok": true, "duration_s": 15.483878, "bars": 8, "tempo": 124.0, "steps": 128,
 "loop_seam_delta": 0.0, "loop_seam_delta_before_fix": 0.053392, "loop_safe": true,
 "peak_db": -2.05, "rms_db": -15.64, "dc_offset": 3e-06, "clipping_ratio": 0.0,
 "counts": {"files": 1, "tracks": 3, "notes": 120, "drum_hits": 96},
 "tracks": [{"name": "lead", "wave": "square", "notes": 56, "tiled": 2}, …],
 "drums": {"kick": 16, "snare": 16, "hat": 64},
 "expect": {"not_silent": true, "no_clipping": true, "loopable": true,
            "min_duration": 15.464, "max_duration": 15.504}}
```

`loop_seam_delta_before_fix` is what the mix actually produced; `loop_seam_delta` is what ended up in the
file. Feed `expect` to `inspect_audio` to re-check the written bytes.

Speed: a 16-bar stereo `overworld` (31 s of audio, 1.37 M frames) renders in about 1.1 s of pure Python.

### Errors name the offender

<!-- replay: fails -->
```bash
python3 /absolute/path/to/godot/scripts/assets/make_music.py --out /absolute/path/to/project/audio/ \
  --song-json '{"tracks":[{"name":"lead","notes":"C4 . H4 ."}]}'
```

```text
error: track 'lead' step 2: unknown note 'H4' - a note is <A-G>[#|b]<octave>, for example "C4", "F#3",
"Bb2"; "." is a rest, "-" holds the previous note, "A4+C5+E5" stacks a chord
```

Unknown song keys, track keys, envelope keys, waveforms, drum voices and drum characters are all rejected
the same way, with the nearest real name and the legal set. Exit code 1, nothing written.

---

## 3. Reading audio as text — `inspect_audio`

```bash
godot --headless --path /absolute/project \
  --script /absolute/godot/scripts/core/dispatcher.gd \
  inspect_audio '{"audio_path":"audio/jump.wav","format":"text","expect":{"not_silent":true,"no_clipping":true,"max_duration":0.4,"pitch_direction":"rising"}}'
```

```
audio_path: res://audio/jump.wav
format: wav (pcm, 16-bit)
duration_s: 0.168277
sample_rate: 44100 Hz, channels: 1, frames: 7421
peak_db: -1.0  rms_db: -5.07  dc_offset: -0.002104
silent: false  clipping_ratio: 0.0
leading_silence_ms: 0.068  trailing_silence_ms: 0.136
loop_seam_delta: 0.000092
dominant_frequency_hz: 339.78 (rising 238.38 -> 480.85, tonality 0.902)
loop: mode=none begin=0 end=0 source=none
import_loop: none (no .import sidecar yet - run godot --headless --path <project> --import)
envelope: |@@@@@@@@@@@@@@@@@@@@@@%%%%%%##**|
expect.not_silent: PASS (expected true, actual true)
expect.max_duration: PASS (expected 0.4, actual 0.168277)
expect.no_clipping: PASS (expected true, actual true)
expect.pitch_direction: PASS (expected rising, actual rising)
```

Full parameter and payload reference: `references/automation_api.md#inspect_audio`. Each file reports its
location twice under the same value — `audio_path` (the `inspect_image` spelling) and `path` (the spelling
the generators print) — so a caller can read whichever key it already knows. The parts that matter when you
cannot hear:

- **`silent`** answers "did anything get synthesized at all". This is the failure `expect.not_silent` exists
  to catch, and it is the most common one: an envelope that sums to zero writes a perfectly valid, perfectly
  inaudible WAV.
- **`peak_db` / `clipping_ratio`** answer "is it usable". `clipping_ratio` is the share of samples pinned at
  full scale; anything above 0 means the mix was clamped.
- **`envelope`** is one ASCII line whose height is the per-slice peak in dB over a 60 dB range
  (`" .:-=+*#%@"`). A decay reads `@@@%%%###***++==--::. `, a whoosh reads `+**###%%%@@@%%%###**+`, and a
  file that is silent after the first tenth reads `@@@@                                    `.
- **`dominant_frequency_hz`, `pitch_start_hz`, `pitch_end_hz`, `pitch_direction`** are the contour. Direction
  is `rising` / `falling` / `flat`, or `none` when the sound has no pitch. `tonality` is 0 (noise) to 1 (a
  perfectly periodic waveform); below 0.6 there is no pitch to report and `dominant_frequency_hz` is `null`
  rather than a made-up number.
- **`loop_seam_delta`** is the jump between the last sample and the first — what a gapless loop actually
  plays at the wrap point. `expect.loopable` gates it (default threshold 0.02; pass a number to set your own).
- **`import_loop`** is what the *game* will hear: the `.import` sidecar's loop settings, or `null` when the
  asset has not been imported yet.

### Formats

| Format | How it is read | Notes |
| --- | --- | --- |
| `.wav` | The RIFF container is parsed directly | 8-, 16-, 24- and 32-bit PCM, 32/64-bit IEEE float, mono to 8 channels, `smpl` loop points |
| `.ogg` | `AudioStreamOggVorbis.load_from_file` + `AudioStreamPlayback.mix_audio` | Full PCM analysis; `sample_rate`/`channels` come from the Vorbis identification header |
| `.mp3` | `AudioStreamMP3.load_from_file` + `AudioStreamPlayback.mix_audio` | Same; `sample_rate`/`channels` from the first frame header (ID3v2 is skipped) |

The WAV path deliberately does **not** go through `AudioStreamWAV.load_from_file`: that helper refuses
24-bit WAV outright (`Format not supported for WAVE file (not PCM)`) and silently converts 32-bit float down
to 16-bit, so it cannot report the file's real bit depth.

A compressed WAV (IMA ADPCM, MS ADPCM, A-law…) is an error, not a guess: the op names the codec and tells
you to re-export as uncompressed PCM. Godot's own imported artifacts (`.godot/imported/*.sample`) are QOA or
IMA-ADPCM — pass the source file, and the error message says so if you do not.

Limits, stated honestly:

- Compressed streams are decoded at `AudioServer.get_mix_rate()` (44100 Hz headless), so a 22050 Hz Ogg is
  analysed after resampling; `analysis_sample_rate` reports it and `sample_rate` still reports the file's own.
  `duration_s` for those comes from `AudioStream.get_length()`, which is exact, not from the mixed frame count.
- A sound shorter than about 25 ms carries no pitch estimate (`pitch_direction: "none"`): there are not
  enough samples for the periodicity test.
- `dominant_frequency_hz` on a full music mix is usually the bass line, or `null`. It is a single-voice
  measurement; do not read it as "the key of the track".

---

## 4. The whole loop, end to end

Run exactly as written, on Godot 4.7. `/absolute/path/to/project` is a project directory and
`/absolute/path/to/godot` the `godot/` skill folder.

**1. Generate.**

```bash
python3 /absolute/path/to/godot/scripts/assets/make_sfx.py --preset jump --seed 7 --out /absolute/path/to/project/audio/
python3 /absolute/path/to/godot/scripts/assets/make_music.py --preset overworld --bars 4 --out /absolute/path/to/project/audio/
```

**2. Verify before importing anything** — generated files have no `.import` yet, and `inspect_audio` reads
them off disk regardless:

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd inspect_audio \
  '{"audio_paths":["audio"],"format":"text","envelope_columns":32,"expect":{"not_silent":true,"no_clipping":true}}'
```

**3. Import**, so `load("res://audio/…")` works in a fresh process:

```bash
godot --headless --path /absolute/path/to/project --import
```

**4. Make the music loop.** The WAV importer's `edit/loop_mode` enum is **offset by one** from
`AudioStreamWAV.LoopMode` — verified on 4.7 by setting `2` and reading `loop_mode` back off the imported
resource as `1` (`LOOP_FORWARD`):

| `edit/loop_mode` (importer) | 0 | 1 | 2 | 3 | 4 |
| --- | --- | --- | --- | --- | --- |
| meaning | Detect From WAV | Disabled | Forward | Ping-Pong | Backward |
| `AudioStreamWAV.loop_mode` | from the `smpl` chunk | 0 `LOOP_DISABLED` | 1 `LOOP_FORWARD` | 2 `LOOP_PINGPONG` | 3 `LOOP_BACKWARD` |

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd set_import_options \
  '{"file_path":"audio/overworld.wav","options":{"edit/loop_mode":2}}'
godot --headless --path /absolute/path/to/project --import
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd inspect_audio \
  '{"audio_path":"audio/overworld.wav","envelope":false,"format":"text","expect":{"loopable":true}}'
```

The last two lines of that read-back:

```text
import_loop: {"edit/loop_mode":2,"import_path":"res://audio/overworld.wav.import","loop_mode_name":"forward"}
expect.loopable: PASS (expected true, actual 0.0)
```

Ogg and MP3 use the simpler `{"loop": true, "loop_offset": 0.0}` instead.

**5. Buses**, so music and effects have independent volume:

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd setup_audio_buses \
  '{"buses":[{"name":"Master","volume_db":0.0},
             {"name":"Music","send":"Master","volume_db":-6.0},
             {"name":"SFX","send":"Master","volume_db":-3.0}],
    "save_path":"audio/default_bus_layout.tres","set_project_setting":true}'
```

```json
{"bus_count":3,"buses":["Master","Music","SFX"],"ok":true,"project_setting_updated":true}
```

**6. Players.** Write the probe script first: `attach_script` loads the script to attach it, so it refuses a
path that holds no file (`Failed to load script: res://scripts/audio_probe.gd`, exit 1) and the whole
`scene_batch` is rolled back with `scene_batch aborted at action: attach_script`.

```bash
cat > /absolute/path/to/project/scripts/audio_probe.gd <<'GDSCRIPT'
extends Node2D

@onready var music: AudioStreamPlayer = $Music
@onready var jump: AudioStreamPlayer = $Jump

var _frames: int = 0


func _ready() -> void:
	music.play()
	jump.play()
	print("[AUDIO] music bus=%s len=%.2fs loop_mode=%d" % [
		music.bus, music.stream.get_length(), (music.stream as AudioStreamWAV).loop_mode])
	print("[AUDIO] jump bus=%s len=%.2fs" % [jump.bus, jump.stream.get_length()])


func _process(_delta: float) -> void:
	# A stream still playing when the engine exits leaks its playback object and
	# run_project.py reports "1 resources still in use at exit". Releasing it a
	# few frames before the smoke run ends keeps the report clean.
	_frames += 1
	if _frames == 20:
		music.stop()
		music.stream = null
GDSCRIPT
```

`scene_batch` then wires the streams, the bus names and that script in one call:

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd scene_batch '{
  "scene_path": "scenes/main.tscn", "create_if_missing": true,
  "root_node_type": "Node2D", "root_node_name": "Main",
  "actions": [
    {"type": "add_node", "node_type": "AudioStreamPlayer", "node_name": "Music",
     "properties": {"stream": {"__resource": "res://audio/overworld.wav"}, "bus": "Music"}},
    {"type": "add_node", "node_type": "AudioStreamPlayer", "node_name": "Jump",
     "properties": {"stream": {"__resource": "res://audio/jump.wav"}, "bus": "SFX"}},
    {"type": "attach_script", "node_path": "root", "script_path": "scripts/audio_probe.gd"}
  ]}'
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd project_batch \
  '{"actions":[{"type":"set_setting","name":"application/run/main_scene","value":"res://scenes/main.tscn"}]}'
```

**7. Run it and read the debugger:**

```bash
python3 /absolute/path/to/godot/scripts/debug/run_project.py /absolute/path/to/project --quit-after 60 --raw
```

```json
{"ok": true, "counts": {"total": 0, "errors": 0, "parse_errors": 0, "warnings": 0}, "diagnostics": [],
 "raw_log": "…\n[AUDIO] music bus=Music len=7.74s loop_mode=1\n[AUDIO] jump bus=SFX len=0.17s\n"}
```

### The exit-time leak, so you do not chase it

A stream that is **still playing when the engine quits** leaks its playback object, and Godot prints

```
ERROR:   1 resources still in use at exit (run with --verbose for details).
WARNING: 2 ObjectDB instances were leaked at exit (run with `--verbose` for details).
```

This is engine exit bookkeeping, not a bug in your scene. It appears whenever a bounded run ends mid-playback
— always, with a looping track — and calling `stop()` in `_exit_tree()` is too late to stop it. The bundled
log parser therefore files these lines as severity `info`, category `exit_leak` (its sibling
`host_capability` covers the Vulkan/ALSA lines a GPU-less or soundcard-less host prints before the engine
falls back): `run_project.py`, `smoke_scenes.py` and `validate_project.py` list them under `diagnostics`
(and `counts.info`) with this explanation, but they never count as an error or a warning and never flip `ok`. A game with background music
passes. If you want the lines gone anyway, two ways, both verified on a real platformer whose player fires a
landing sound as it drops onto the floor:

- **Let the sound finish.** `run_project.py PROJECT --quit-after 40` reported the leak, `--quit-after 90`
  (past the end of the 0.19 s landing sound) reported `{"errors": 0, "warnings": 0}`. Raising `--quit-after`
  is the cheapest fix for a short effect.
- **Release it early** for a track that never ends: `player.stop(); player.stream = null` a few frames before
  the run does, the way the probe above does. The combination matters — `stop()` alone is not enough.

---

## 5. Wiring it into a real game

`templates/gdscript/audio_manager.gd` is an autoload with a pool of `AudioStreamPlayer`s for effects and a
two-player crossfade for music — overlapping sounds never cut each other off and a track change never pops.
Register it after the buses exist:

```bash
cp /absolute/path/to/godot/templates/gdscript/audio_manager.gd /absolute/path/to/project/scripts/audio_manager.gd
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd project_batch \
  '{"actions":[{"type":"add_autoload","autoload_name":"AudioManager","path":"res://scripts/audio_manager.gd"}]}'
```

```gdscript
AudioManager.play_sfx(preload("res://audio/jump.wav"))
AudioManager.play_music(preload("res://audio/overworld.wav"))
```

Route an individual player to a bus with `configure_node`:
`{"properties": {"bus": "Music"}}` on the `AudioStreamPlayer`.

## 6. The no-hearing checklist

1. Generate with `make_sfx.py` / `make_music.py`; keep the `expect` block each one prints.
2. `inspect_audio` with that `expect` — exit 0 or the message tells you which number is wrong and how to fix it.
3. `--import`, then `set_import_options` for loops, then `inspect_audio` again to confirm `import_loop`.
4. `run_project.py` (or a `run_scenario.py` scenario) so a missing `.import`, a wrong bus name or a null
   stream surfaces as a diagnostic instead of as silence.
5. Never assume a file is fine because it exists. A zero-length envelope, a muted bus and a stream that was
   never assigned all look identical from the filesystem — and all three are caught by steps 2 and 4.
