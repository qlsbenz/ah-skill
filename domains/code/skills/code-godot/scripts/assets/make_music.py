#!/usr/bin/env python3
"""Tiny chiptune tracker: a JSON song -> one seamlessly looping 16-bit PCM WAV.

Background music is the other half of "the agent has no sound source". This is a
step sequencer, not a sampler: notes are written as text (``"C4 . E4 - G4 ."``),
turned into equal-tempered frequencies (A4 = 440 Hz), rendered with per-track
ADSR envelopes so no note clicks, and mixed with synthesized drums (kick =
pitch-dropping sine, snare = noise + tone, hat = high-passed noise burst).

The loop is seamless **by construction**: the output buffer is exactly one loop
long and every note's release tail wraps around into the start of the buffer, so
the last sample flows into the first. The remaining sample step at the seam is
measured, corrected over the final two milliseconds, and reported as
``loop_seam_delta`` / ``loop_safe`` — which is what ``inspect_audio``'s
``expect.loopable`` re-checks on the written file.

Stdlib only. Examples::

    python3 make_music.py --list-presets
    python3 make_music.py --preset overworld --out /abs/project/audio/overworld.wav
    python3 make_music.py --preset battle --bars 16 --tempo 168 --out /abs/project/audio/
    python3 make_music.py --song song.json --stereo --out /abs/project/audio/theme.wav
"""
from __future__ import annotations

import argparse
import json
import math
import os
import random
import re
import sys
from operator import add
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from make_sfx import (  # noqa: E402
    SfxError,
    analyse,
    nearest,
    write_wav,
)

# --- song schema ------------------------------------------------------------
SONG_KEYS = {
    "name": "label carried into the JSON report",
    "tempo": "beats per minute (20-400)",
    "steps_per_beat": "grid resolution; 4 = sixteenth notes",
    "beats_per_bar": "time signature numerator (default 4)",
    "bars": "loop length in bars; patterns are tiled to fill it",
    "master_volume": "0-1 gain before normalisation",
    "sample_rate": "output rate in Hz (default 44100)",
    "tracks": "[{name, wave, duty, volume, octave, envelope, notes, pan}]",
    "drums": "{volume, kick, snare, hat, tom, clap} - each a row like \"x...x...\"",
}
TRACK_KEYS = {
    "name": "label used in errors and the report",
    "wave": "square | saw | triangle | sine | noise",
    "duty": "square pulse width 0.01-0.99 (default 0.5)",
    "volume": "0-1 track gain (default 0.8)",
    "octave": "integer transpose in octaves (default 0)",
    "envelope": "{attack, decay, sustain_level, release} in seconds (sustain_level 0-1)",
    "notes": "\"C4 . E4 - G4 .\" or [{note, len}]; \".\" rests, \"-\" holds, \"+\" stacks a chord",
    "pan": "-1 left .. 1 right, only used with --stereo (default 0)",
}
ENVELOPE_KEYS = ("attack", "decay", "sustain_level", "release")
DRUM_VOICES = ("kick", "snare", "hat", "tom", "clap")
DRUM_KEYS = ("volume",) + DRUM_VOICES
WAVES = ("square", "saw", "triangle", "sine", "noise")

DEFAULT_ENVELOPE = {"attack": 0.004, "decay": 0.03, "sustain_level": 0.7, "release": 0.05}
# Hard floors: a note that starts or stops instantly is the click a tracker must
# never produce, so these are clamped up rather than trusted.
MIN_ATTACK = 0.002
MIN_RELEASE = 0.005
SEAM_FIX_MS = 2.0
LOOP_SEAM_THRESHOLD = 0.02

NOTE_PATTERN = re.compile(r"^([A-Ga-g])([#b]?)(-?\d)$")
NOTE_LETTERS = {"c": 0, "d": 2, "e": 4, "f": 5, "g": 7, "a": 9, "b": 11}
NOTE_SYNTAX = ('a note is <A-G>[#|b]<octave>, for example "C4", "F#3", "Bb2"; '
               '"." is a rest, "-" holds the previous note, "A4+C5+E5" stacks a chord')


class SongError(SfxError):
    """A user-facing song problem; always names the track and the step."""


# --- presets ----------------------------------------------------------------
def _bars(*lines: str) -> str:
    return " ".join(lines)


PRESETS: dict[str, dict] = {
    "menu": {
        "name": "menu",
        "tempo": 88,
        "steps_per_beat": 4,
        "beats_per_bar": 4,
        "bars": 8,
        "master_volume": 0.85,
        "tracks": [
            {"name": "pad", "wave": "triangle", "volume": 0.55, "pan": -0.25,
             "envelope": {"attack": 0.06, "decay": 0.12, "sustain_level": 0.75, "release": 0.25},
             "notes": _bars(
                 "A3+C4+E4 - - - - - - - - - - - - - - -",
                 "F3+A3+C4 - - - - - - - - - - - - - - -",
                 "C4+E4+G4 - - - - - - - - - - - - - - -",
                 "G3+B3+D4 - - - - - - - - - - - - - - -")},
            {"name": "lead", "wave": "square", "duty": 0.25, "volume": 0.5, "pan": 0.3,
             "envelope": {"attack": 0.01, "decay": 0.06, "sustain_level": 0.55, "release": 0.14},
             "notes": _bars(
                 "E5 - - . C5 - - . A4 - - - - - . .",
                 "F5 - - . C5 - - . A4 - - - - - . .",
                 "G5 - - . E5 - - . C5 - - - - - . .",
                 "D5 - - . B4 - - . G4 - - - - - . .")},
            {"name": "bass", "wave": "triangle", "volume": 0.7,
             "envelope": {"attack": 0.006, "decay": 0.05, "sustain_level": 0.6, "release": 0.1},
             "notes": _bars(
                 "A2 - - - - - - - E2 - - - - - - -",
                 "F2 - - - - - - - C3 - - - - - - -",
                 "C3 - - - - - - - G2 - - - - - - -",
                 "G2 - - - - - - - D3 - - - - - - -")},
        ],
        "drums": {"volume": 0.35, "hat": "....x.......x..."},
    },
    "overworld": {
        "name": "overworld",
        "tempo": 124,
        "steps_per_beat": 4,
        "beats_per_bar": 4,
        "bars": 8,
        "master_volume": 0.9,
        "tracks": [
            {"name": "lead", "wave": "square", "duty": 0.5, "volume": 0.75, "pan": 0.2,
             "envelope": {"attack": 0.004, "decay": 0.035, "sustain_level": 0.68, "release": 0.055},
             "notes": _bars(
                 "C5 - E5 - G5 - E5 - F5 - E5 - D5 - . -",
                 "C5 - E5 - G5 - C6 - B5 - G5 - E5 - . -",
                 "A4 - C5 - F5 - A5 - G5 - F5 - E5 - . -",
                 "G4 - B4 - D5 - G5 - F5 - D5 - C5 - - -")},
            {"name": "harmony", "wave": "square", "duty": 0.25, "volume": 0.4, "pan": -0.3,
             "envelope": {"attack": 0.003, "decay": 0.05, "sustain_level": 0.3, "release": 0.06},
             "notes": _bars(
                 ". . C4+E4+G4 . . . C4+E4+G4 . . . C4+E4+G4 . . . C4+E4+G4 .",
                 ". . C4+E4+G4 . . . C4+E4+G4 . . . G3+B3+D4 . . . G3+B3+D4 .",
                 ". . F3+A3+C4 . . . F3+A3+C4 . . . F3+A3+C4 . . . F3+A3+C4 .",
                 ". . G3+B3+D4 . . . G3+B3+D4 . . . G3+B3+D4 . . . G3+B3+D4 .")},
            {"name": "bass", "wave": "triangle", "volume": 0.85,
             "envelope": {"attack": 0.004, "decay": 0.04, "sustain_level": 0.55, "release": 0.05},
             "notes": _bars(
                 "C3 - - - G2 - - - C3 - - - E3 - - -",
                 "C3 - - - G2 - - - G2 - - - B2 - - -",
                 "F2 - - - C3 - - - F2 - - - A2 - - -",
                 "G2 - - - D3 - - - G2 - - - B2 - - -")},
        ],
        "drums": {"volume": 0.8, "kick": "x.......x.......", "snare": "....x.......x...",
                  "hat": "x.x.x.x.x.x.x.x."},
    },
    "battle": {
        "name": "battle",
        "tempo": 168,
        "steps_per_beat": 4,
        "beats_per_bar": 4,
        "bars": 8,
        "master_volume": 0.92,
        "tracks": [
            {"name": "lead", "wave": "square", "duty": 0.35, "volume": 0.72, "pan": 0.25,
             "envelope": {"attack": 0.003, "decay": 0.025, "sustain_level": 0.6, "release": 0.04},
             "notes": _bars(
                 "A4 . A4 . C5 . A4 . E5 . D5 . C5 . B4 .",
                 "A4 . A4 . C5 . E5 . G5 . E5 . D5 . C5 .",
                 "F4 . F4 . A4 . C5 . E5 . C5 . A4 . G4 .",
                 "E4 . G4 . B4 . E5 . D5 . B4 . G4 . E4 .")},
            {"name": "stabs", "wave": "saw", "volume": 0.35, "pan": -0.3,
             "envelope": {"attack": 0.003, "decay": 0.04, "sustain_level": 0.25, "release": 0.05},
             "notes": _bars(
                 "A3+C4+E4 . . . A3+C4+E4 . . . A3+C4+E4 . . . A3+C4+E4 . . .",
                 "A3+C4+E4 . . . A3+C4+E4 . . . G3+B3+D4 . . . G3+B3+D4 . . .",
                 "F3+A3+C4 . . . F3+A3+C4 . . . F3+A3+C4 . . . F3+A3+C4 . . .",
                 "E3+G3+B3 . . . E3+G3+B3 . . . E3+G3+B3 . . . E3+G3+B3 . . .")},
            {"name": "bass", "wave": "square", "duty": 0.5, "volume": 0.9,
             "envelope": {"attack": 0.003, "decay": 0.03, "sustain_level": 0.5, "release": 0.035},
             "notes": _bars(
                 "A2 . A2 . A2 . A2 . A2 . A2 . A2 . G2 .",
                 "A2 . A2 . A2 . A2 . G2 . G2 . G2 . G2 .",
                 "F2 . F2 . F2 . F2 . F2 . F2 . F2 . E2 .",
                 "E2 . E2 . E2 . E2 . E2 . E2 . E2 . E2 .")},
        ],
        "drums": {"volume": 0.95, "kick": "x...x..xx...x...", "snare": "....x.......x...",
                  "hat": "xxxxxxxxxxxxxxxx", "tom": "..............x."},
    },
    "victory": {
        "name": "victory",
        "tempo": 140,
        "steps_per_beat": 4,
        "beats_per_bar": 4,
        "bars": 4,
        "master_volume": 0.9,
        "tracks": [
            {"name": "fanfare", "wave": "square", "duty": 0.5, "volume": 0.8, "pan": 0.15,
             "envelope": {"attack": 0.004, "decay": 0.03, "sustain_level": 0.75, "release": 0.08},
             "notes": _bars(
                 "C5 . E5 . G5 . C6 - - - . . G5 . . .",
                 "C6 - - - - - - - . . . . . . . .",
                 "G5 . A5 . B5 . C6 - - - . . B5 . . .",
                 "C6 - - - - - - - - - - - - - . .")},
            {"name": "counter", "wave": "square", "duty": 0.25, "volume": 0.45, "pan": -0.25,
             "envelope": {"attack": 0.004, "decay": 0.04, "sustain_level": 0.5, "release": 0.08},
             "notes": _bars(
                 "E4+G4 . . . E4+G4 . . . E4+G4 . . . E4+G4 . . .",
                 "E4+G4+C5 - - - - - - - . . . . . . . .",
                 "D4+F4 . . . D4+F4 . . . D4+G4 . . . D4+G4 . . .",
                 "E4+G4+C5 - - - - - - - - - - - - - . .")},
            {"name": "bass", "wave": "triangle", "volume": 0.85,
             "envelope": {"attack": 0.004, "decay": 0.04, "sustain_level": 0.6, "release": 0.06},
             "notes": _bars(
                 "C3 - - - C3 - - - C3 - - - G2 - - -",
                 "C3 - - - - - - - . . . . . . . .",
                 "G2 - - - G2 - - - G2 - - - G2 - - -",
                 "C3 - - - - - - - - - - - - - . .")},
        ],
        "drums": {"volume": 0.85, "kick": "x...x...x...x...", "snare": "x.x.x.x.x.x.x.x.",
                  "hat": "..x...x...x...x."},
    },
}


# --- CLI --------------------------------------------------------------------

def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Render a JSON song into one seamlessly looping chiptune WAV.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="Run --list-presets and copy a preset's \"song\" object into a file to edit it.",
    )
    parser.add_argument("--preset", help="Built-in song. See --list-presets.")
    parser.add_argument("--song", help="Path to a song JSON file.")
    parser.add_argument("--song-json", help="Song JSON given inline.")
    parser.add_argument("--out", help="Output .wav file, or a directory (default: <name>.wav in the current directory).")
    parser.add_argument("--name", help="Override the song name / output stem.")
    parser.add_argument("--bars", type=int, help="Override the loop length in bars.")
    parser.add_argument("--tempo", type=float, help="Override the tempo in BPM.")
    parser.add_argument("--sample-rate", type=int, help="Override the sample rate in Hz.")
    parser.add_argument("--stereo", action="store_true", help="Render two channels and honour each track's pan.")
    parser.add_argument("--seed", type=int, default=0, help="Seed for the drum noise (default: 0).")
    parser.add_argument("--peak-db", type=float, default=-1.0, help="Normalisation target in dBFS (default: -1.0).")
    parser.add_argument("--overwrite", action="store_true", default=True, help="Overwrite an existing file (default).")
    parser.add_argument("--no-overwrite", dest="overwrite", action="store_false",
                        help="Fail instead of overwriting an existing file.")
    parser.add_argument("--list-presets", action="store_true", help="Print every preset's full song JSON and exit.")
    parser.add_argument("--pretty", action="store_true", help="Indent the JSON output.")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(list(sys.argv[1:] if argv is None else argv))
    try:
        payload = run(args)
    except SfxError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    print(json.dumps(payload, indent=2 if args.pretty else None, sort_keys=False))
    return 0


def run(args: argparse.Namespace) -> dict:
    if args.list_presets:
        return {
            "ok": True,
            "counts": {"presets": len(PRESETS)},
            "waves": list(WAVES),
            "drum_voices": list(DRUM_VOICES),
            "note_syntax": NOTE_SYNTAX,
            "song_keys": SONG_KEYS,
            "track_keys": TRACK_KEYS,
            "usage": "make_music.py --preset <name> --out DIR_OR_FILE [--bars N] [--tempo N] [--stereo]",
            "presets": {name: {"song": song} for name, song in sorted(PRESETS.items())},
        }

    song = load_song(args)
    if args.bars is not None:
        song["bars"] = args.bars
    if args.tempo is not None:
        song["tempo"] = args.tempo
    if args.sample_rate is not None:
        song["sample_rate"] = args.sample_rate
    if args.name:
        song["name"] = args.name
    plan = validate_song(song)

    target = resolve_output(args.out, plan["name"])
    if not args.overwrite and target.exists():
        raise SongError(f"refusing to overwrite {target} (drop --no-overwrite or pick another --out)")

    channels = 2 if args.stereo else 1
    rendered = render_song(plan, channels, args.seed)
    samples, seam_before, seam_after = finalise(
        rendered, channels, plan["sample_rate"], args.peak_db, plan["master_volume"])

    target.parent.mkdir(parents=True, exist_ok=True)
    write_wav(target, samples, plan["sample_rate"], channels)

    summary = analyse(samples, plan["sample_rate"], channels)
    summary["path"] = str(target)
    step_seconds = 60.0 / plan["tempo"] / plan["steps_per_beat"]
    return {
        "ok": True,
        "counts": {"files": 1, "tracks": len(plan["tracks"]), "notes": plan["note_count"],
                   "drum_hits": plan["drum_hits"]},
        "preset": args.preset,
        "name": plan["name"],
        "tempo": plan["tempo"],
        "bars": plan["bars"],
        "beats_per_bar": plan["beats_per_bar"],
        "steps_per_beat": plan["steps_per_beat"],
        "steps": plan["total_steps"],
        "step_seconds": round(step_seconds, 6),
        "loop_seam_delta": round(seam_after, 6),
        "loop_seam_delta_before_fix": round(seam_before, 6),
        "loop_safe": seam_after <= LOOP_SEAM_THRESHOLD,
        "needs_import": True,
        "tracks": [{"name": track["name"], "wave": track["wave"], "notes": track["note_count"],
                    "tiled": track["tiles"]} for track in plan["tracks"]],
        "drums": plan["drum_summary"],
        "expect": {"not_silent": True, "no_clipping": True, "loopable": True,
                   "min_duration": round(summary["duration_s"] - 0.02, 3),
                   "max_duration": round(summary["duration_s"] + 0.02, 3)},
        **summary,
    }


def load_song(args: argparse.Namespace) -> dict:
    sources = [name for name, value in
               (("--preset", args.preset), ("--song", args.song), ("--song-json", args.song_json)) if value]
    if not sources:
        raise SongError("give a song: --preset <name> (see --list-presets), --song FILE, or --song-json '{...}'")
    if len(sources) > 1:
        raise SongError(f"pass only one of {', '.join(sources)}")
    if args.preset:
        if args.preset not in PRESETS:
            raise SongError(f"unknown preset {args.preset!r}{nearest(args.preset, PRESETS)}. "
                            f"Presets: {', '.join(sorted(PRESETS))}")
        return json.loads(json.dumps(PRESETS[args.preset]))
    if args.song:
        path = Path(args.song).expanduser()
        if not path.is_file():
            raise SongError(f"--song does not exist: {path}")
        text = path.read_text(encoding="utf-8")
        label = f"--song {path}"
    else:
        text, label = args.song_json, "--song-json"
    try:
        value = json.loads(text)
    except json.JSONDecodeError as error:
        raise SongError(f"{label} is not valid JSON: {error}") from error
    if not isinstance(value, dict):
        raise SongError(f"{label} must be a JSON object with a \"tracks\" list; see --list-presets for the shape")
    return value


def resolve_output(out: str | None, name: str) -> Path:
    stem = name or "music"
    if out is None:
        return Path.cwd() / f"{stem}.wav"
    path = Path(out).expanduser()
    if path.suffix.lower() == ".wav":
        return path
    return path / f"{stem}.wav"


# --- validation -------------------------------------------------------------

def validate_song(song: dict) -> dict:
    unknown = [key for key in song if key not in SONG_KEYS]
    if unknown:
        raise SongError(f"unknown song key(s) {', '.join(sorted(unknown))}"
                        f"{nearest(unknown[0], SONG_KEYS)}. Keys: {', '.join(sorted(SONG_KEYS))}")
    tempo = _number(song, "tempo", 120.0, 20.0, 400.0, "song")
    steps_per_beat = _integer(song, "steps_per_beat", 4, 1, 16, "song")
    beats_per_bar = _integer(song, "beats_per_bar", 4, 1, 16, "song")
    sample_rate = _integer(song, "sample_rate", 44100, 8000, 192000, "song")
    master_volume = _number(song, "master_volume", 0.9, 0.01, 1.0, "song")
    name = str(song.get("name") or "music").strip() or "music"

    raw_tracks = song.get("tracks", [])
    if not isinstance(raw_tracks, list):
        raise SongError('song "tracks" must be a list of track objects')
    raw_drums = song.get("drums", {}) or {}
    if not isinstance(raw_drums, dict):
        raise SongError('song "drums" must be an object like {"kick": "x...x...", "snare": "....x..."}')
    drum_rows = validate_drums(raw_drums)
    if not raw_tracks and not drum_rows:
        raise SongError('the song has no tracks and no drum rows; add at least one '
                        '{"name": "lead", "wave": "square", "notes": "C4 . E4 ."}')

    steps_per_bar = steps_per_beat * beats_per_bar
    tracks = []
    longest = 0
    for index, raw in enumerate(raw_tracks):
        track = validate_track(raw, index)
        longest = max(longest, len(track["tokens"]))
        tracks.append(track)
    for row in drum_rows.values():
        longest = max(longest, len(row))

    bars_value = song.get("bars")
    if bars_value is None:
        bars = max(1, math.ceil(longest / steps_per_bar)) if longest else 1
    else:
        if isinstance(bars_value, bool) or not isinstance(bars_value, int) or not 1 <= bars_value <= 256:
            raise SongError(f'song "bars" must be an integer from 1 to 256; got {bars_value!r}')
        bars = bars_value
    total_steps = bars * steps_per_bar

    note_count = 0
    for track in tracks:
        track["events"], track["tiles"] = build_events(track, total_steps)
        track["note_count"] = len(track["events"])
        note_count += track["note_count"]

    drum_hits = 0
    drum_summary = {}
    drums = {}
    for voice, row in drum_rows.items():
        tiled = _tile(list(row), total_steps)
        hits = [(index, char == "X") for index, char in enumerate(tiled) if char in "xX"]
        drums[voice] = hits
        drum_hits += len(hits)
        drum_summary[voice] = len(hits)
    drum_volume = _number(raw_drums, "volume", 0.85, 0.0, 1.0, "drums")

    return {
        "name": name, "tempo": tempo, "steps_per_beat": steps_per_beat, "beats_per_bar": beats_per_bar,
        "bars": bars, "total_steps": total_steps, "sample_rate": sample_rate,
        "master_volume": master_volume, "tracks": tracks, "drums": drums,
        "drum_volume": drum_volume, "drum_summary": drum_summary,
        "note_count": note_count, "drum_hits": drum_hits,
    }


def validate_track(raw: object, index: int) -> dict:
    if not isinstance(raw, dict):
        raise SongError(f"tracks[{index}] must be an object with \"notes\"; got {raw!r}")
    label = str(raw.get("name") or f"tracks[{index}]")
    unknown = [key for key in raw if key not in TRACK_KEYS]
    if unknown:
        raise SongError(f"track {label!r}: unknown key(s) {', '.join(sorted(unknown))}"
                        f"{nearest(unknown[0], TRACK_KEYS)}. Keys: {', '.join(sorted(TRACK_KEYS))}")
    wave = str(raw.get("wave", "square"))
    if wave not in WAVES:
        raise SongError(f"track {label!r}: unknown wave {wave!r}"
                        f"{nearest(wave, dict.fromkeys(WAVES))}. Waves: {', '.join(WAVES)}")
    envelope = dict(DEFAULT_ENVELOPE)
    raw_envelope = raw.get("envelope", {})
    if raw_envelope:
        if not isinstance(raw_envelope, dict):
            raise SongError(f'track {label!r}: "envelope" must be an object '
                            f'{{"attack": 0.005, "decay": 0.03, "sustain_level": 0.7, "release": 0.05}}')
        for key in raw_envelope:
            if key not in ENVELOPE_KEYS:
                raise SongError(f"track {label!r}: unknown envelope key {key!r}"
                                f"{nearest(key, dict.fromkeys(ENVELOPE_KEYS))}. "
                                f"Keys: {', '.join(ENVELOPE_KEYS)}")
        envelope.update(raw_envelope)
    for key in ENVELOPE_KEYS:
        high = 1.0 if key == "sustain_level" else 4.0
        value = envelope[key]
        if isinstance(value, bool) or not isinstance(value, (int, float)) or not 0.0 <= float(value) <= high:
            raise SongError(f"track {label!r}: envelope.{key} must be a number from 0 to {high}; got {value!r}")
    envelope["attack"] = max(MIN_ATTACK, float(envelope["attack"]))
    envelope["release"] = max(MIN_RELEASE, float(envelope["release"]))

    octave = raw.get("octave", 0)
    if isinstance(octave, bool) or not isinstance(octave, int) or not -4 <= octave <= 4:
        raise SongError(f"track {label!r}: \"octave\" must be an integer from -4 to 4; got {octave!r}")
    return {
        "name": label,
        "wave": wave,
        "duty": _number(raw, "duty", 0.5, 0.01, 0.99, f"track {label!r}"),
        "volume": _number(raw, "volume", 0.8, 0.0, 1.0, f"track {label!r}"),
        "pan": _number(raw, "pan", 0.0, -1.0, 1.0, f"track {label!r}"),
        "octave": octave,
        "envelope": envelope,
        "tokens": parse_notes(raw.get("notes", ""), label),
    }


def validate_drums(raw: dict) -> dict:
    unknown = [key for key in raw if key not in DRUM_KEYS]
    if unknown:
        raise SongError(f"drums: unknown key(s) {', '.join(sorted(unknown))}"
                        f"{nearest(unknown[0], dict.fromkeys(DRUM_KEYS))}. Keys: {', '.join(DRUM_KEYS)}")
    rows = {}
    for voice in DRUM_VOICES:
        if voice not in raw:
            continue
        row = raw[voice]
        if not isinstance(row, str) or not row.strip():
            raise SongError(f'drums.{voice} must be a pattern string like "x...x..."; got {row!r}')
        cleaned = row.replace(" ", "")
        for position, char in enumerate(cleaned):
            if char not in "xX.-_":
                raise SongError(f"drums.{voice} step {position}: unknown character {char!r} - "
                                f'use "x" for a hit, "X" for an accent and "." for a rest')
        rows[voice] = cleaned
    return rows


def parse_notes(raw: object, label: str) -> list[list[float] | None | str]:
    """-> one entry per step: a list of frequencies, None (rest) or "-" (hold)."""
    if isinstance(raw, str):
        tokens = raw.split()
    elif isinstance(raw, list):
        tokens = []
        for index, item in enumerate(raw):
            if isinstance(item, str):
                tokens.append(item)
                continue
            if not isinstance(item, dict) or "note" not in item:
                raise SongError(f'track {label!r} step {index}: list entries must be "C4" or '
                                f'{{"note": "C4", "len": 2}}; got {item!r}')
            unknown = set(item) - {"note", "len"}
            if unknown:
                raise SongError(f"track {label!r} step {index}: unknown key(s) {sorted(unknown)}; "
                                f'allowed: "note", "len"')
            length = item.get("len", 1)
            if isinstance(length, bool) or not isinstance(length, int) or length < 1:
                raise SongError(f'track {label!r} step {index}: "len" must be an integer >= 1; got {length!r}')
            tokens.append(str(item["note"]))
            tokens.extend(["-"] * (length - 1))
    else:
        raise SongError(f'track {label!r}: "notes" must be a string like "C4 . E4 ." or a list; got {raw!r}')
    if not tokens:
        raise SongError(f'track {label!r}: "notes" is empty - give it at least one step, e.g. "C4 . . ."')

    steps: list[list[float] | None | str] = []
    for index, token in enumerate(tokens):
        if token in (".", "_"):
            steps.append(None)
        elif token == "-":
            steps.append("-")
        else:
            steps.append([note_to_hz(part, label, index) for part in token.split("+")])
    return steps


def note_to_hz(token: str, label: str, step: int) -> float:
    match = NOTE_PATTERN.match(token.strip())
    if match is None:
        raise SongError(f"track {label!r} step {step}: unknown note {token!r} - {NOTE_SYNTAX}")
    letter, accidental, octave = match.group(1).lower(), match.group(2), int(match.group(3))
    if not -1 <= octave <= 9:
        raise SongError(f"track {label!r} step {step}: octave {octave} in {token!r} is out of range "
                        f"(-1 to 9) - {NOTE_SYNTAX}")
    semitone = NOTE_LETTERS[letter] + (1 if accidental == "#" else -1 if accidental == "b" else 0)
    midi = 12 * (octave + 1) + semitone
    return 440.0 * (2.0 ** ((midi - 69) / 12.0))


def build_events(track: dict, total_steps: int) -> tuple[list[dict], int]:
    """Collapse the step grid into (start_step, length_steps, frequencies) events,
    tiling the written pattern until the loop is full."""
    tokens = track["tokens"]
    tiles = max(1, math.ceil(total_steps / len(tokens)))
    grid = _tile(tokens, total_steps)
    shift = 2.0 ** track["octave"]
    events: list[dict] = []
    for index, entry in enumerate(grid):
        if entry == "-":
            if events and events[-1]["end"] == index:
                events[-1]["end"] = index + 1
            continue
        if entry is None:
            continue
        events.append({"start": index, "end": index + 1,
                       "freqs": [value * shift for value in entry]})
    return events, tiles


def _tile(items: list, total: int) -> list:
    if len(items) >= total:
        return items[:total]
    repeated = items * (total // len(items) + 1)
    return repeated[:total]


def _number(source: dict, key: str, default: float, low: float, high: float, where: str) -> float:
    value = source.get(key, default)
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise SongError(f"{where}: \"{key}\" must be a number from {low} to {high}; got {value!r}")
    if not low <= float(value) <= high:
        raise SongError(f"{where}: \"{key}\" must be between {low} and {high}; got {value}")
    return float(value)


def _integer(source: dict, key: str, default: int, low: int, high: int, where: str) -> int:
    value = source.get(key, default)
    if isinstance(value, bool) or not isinstance(value, int):
        raise SongError(f"{where}: \"{key}\" must be a whole number from {low} to {high}; got {value!r}")
    if not low <= value <= high:
        raise SongError(f"{where}: \"{key}\" must be between {low} and {high}; got {value}")
    return value


# --- rendering --------------------------------------------------------------

def render_song(plan: dict, channels: int, seed: int) -> list[list[float]]:
    sample_rate = plan["sample_rate"]
    step_seconds = 60.0 / plan["tempo"] / plan["steps_per_beat"]
    loop_frames = max(2, int(round(plan["total_steps"] * step_seconds * sample_rate)))
    buses = [[0.0] * loop_frames for _ in range(channels)]

    for track in plan["tracks"]:
        buffer = render_track(track, step_seconds, sample_rate, loop_frames)
        _mix_into(buses, buffer, track["pan"] if channels == 2 else 0.0)
    if plan["drums"]:
        buffer = render_drums(plan, step_seconds, sample_rate, loop_frames, seed)
        _mix_into(buses, buffer, 0.0)
    return buses


def _offset(bus: list[float], shift: float, gain: float) -> list[float]:
    return [(value + shift) * gain for value in bus]


def _mix_into(buses: list[list[float]], buffer: list[float], pan: float) -> None:
    """Constant-power pan into the master buses. `master_volume` is applied after
    normalisation instead of here, where the peak normalise would cancel it."""
    if len(buses) == 1:
        buses[0][:] = list(map(add, buses[0], buffer))
        return
    angle = (pan + 1.0) * math.pi / 4.0
    left = math.cos(angle) * math.sqrt(2.0)
    right = math.sin(angle) * math.sqrt(2.0)
    buses[0][:] = list(map(add, buses[0], [value * left for value in buffer]))
    buses[1][:] = list(map(add, buses[1], [value * right for value in buffer]))


def render_track(track: dict, step_seconds: float, sample_rate: int, loop_frames: int) -> list[float]:
    """Bodies first (disjoint, so they can be slice-assigned at C speed), release
    tails second (short, added, wrapping around the loop)."""
    buffer = [0.0] * loop_frames
    envelope = track["envelope"]
    release_frames = max(1, int(round(envelope["release"] * sample_rate)))
    cache: dict[tuple, tuple[list[float], list[float]]] = {}
    bodies: list[tuple[int, list[float]]] = []
    tails: list[tuple[int, list[float]]] = []

    for event in track["events"]:
        start = int(round(event["start"] * step_seconds * sample_rate))
        gate = int(round(event["end"] * step_seconds * sample_rate)) - start
        if gate <= 0:
            continue
        key = (gate, tuple(round(value, 4) for value in event["freqs"]))
        rendered = cache.get(key)
        if rendered is None:
            rendered = _render_note(track, event["freqs"], gate, release_frames, sample_rate)
            cache[key] = rendered
        bodies.append((start, rendered[0]))
        tails.append((start + gate, rendered[1]))

    for start, body in bodies:
        stop = start + len(body)
        if stop <= loop_frames:
            buffer[start:stop] = body
        else:
            buffer[start:loop_frames] = body[:loop_frames - start]
            wrapped = body[loop_frames - start:]
            for index, value in enumerate(wrapped):
                buffer[index % loop_frames] += value
    for start, tail in tails:
        for index, value in enumerate(tail):
            buffer[(start + index) % loop_frames] += value
    return buffer


def _render_note(track: dict, freqs: list[float], gate: int, release_frames: int,
                 sample_rate: int) -> tuple[list[float], list[float]]:
    envelope = track["envelope"]
    attack = min(gate, max(1, int(round(envelope["attack"] * sample_rate))))
    decay = min(gate - attack, max(0, int(round(envelope["decay"] * sample_rate))))
    level = float(envelope["sustain_level"])
    wave = track["wave"]
    duty = track["duty"]
    volume = track["volume"] / math.sqrt(len(freqs))
    tau = math.tau
    inv_rate = 1.0 / sample_rate

    shape = [0.0] * (gate + release_frames)
    for index in range(attack):
        shape[index] = (index + 1) / attack
    for index in range(decay):
        shape[attack + index] = 1.0 + (level - 1.0) * (index + 1) / decay
    # With no decay stage the note simply holds at full level: stepping straight
    # down to sustain_level would be a click.
    hold = level if decay else 1.0
    for index in range(attack + decay, gate):
        shape[index] = hold
    tail_start = shape[gate - 1] if gate else hold
    for index in range(release_frames):
        shape[gate + index] = tail_start * (1.0 - (index + 1) / release_frames) ** 1.5

    total = gate + release_frames
    samples = [0.0] * total
    for freq in freqs:
        increment = freq * inv_rate
        phase = 0.0
        if wave == "square":
            for index in range(total):
                phase += increment
                if phase >= 1.0:
                    phase -= int(phase)
                samples[index] += (1.0 if phase < duty else -1.0) * shape[index]
        elif wave == "saw":
            for index in range(total):
                phase += increment
                if phase >= 1.0:
                    phase -= int(phase)
                samples[index] += (1.0 - 2.0 * phase) * shape[index]
        elif wave == "triangle":
            for index in range(total):
                phase += increment
                if phase >= 1.0:
                    phase -= int(phase)
                samples[index] += (4.0 * abs(phase - 0.5) - 1.0) * shape[index]
        elif wave == "sine":
            for index in range(total):
                phase += increment
                if phase >= 1.0:
                    phase -= int(phase)
                samples[index] += math.sin(tau * phase) * shape[index]
        else:  # noise
            rng = random.Random(int(freq * 1000))
            for index in range(total):
                samples[index] += rng.uniform(-1.0, 1.0) * shape[index]
    if volume != 1.0:
        samples = [value * volume for value in samples]
    return samples[:gate], samples[gate:]


def render_drums(plan: dict, step_seconds: float, sample_rate: int,
                 loop_frames: int, seed: int) -> list[float]:
    buffer = [0.0] * loop_frames
    voices = {voice: _drum_voice(voice, sample_rate, seed) for voice in plan["drums"]}
    gain = plan["drum_volume"]
    for voice, hits in plan["drums"].items():
        sample = voices[voice]
        for step, accent in hits:
            start = int(round(step * step_seconds * sample_rate))
            level = gain * (1.25 if accent else 1.0)
            for index, value in enumerate(sample):
                buffer[(start + index) % loop_frames] += value * level
    return buffer


def _drum_voice(voice: str, sample_rate: int, seed: int) -> list[float]:
    """Synthesized one-shots. Deterministic: the noise RNG is seeded per voice."""
    rng = random.Random("drum:%s:%d" % (voice, seed))
    tau = math.tau
    inv_rate = 1.0 / sample_rate

    def envelope(length: int, decay_s: float) -> list[float]:
        return [math.exp(-index * inv_rate / decay_s) for index in range(length)]

    if voice == "kick":
        length = int(0.30 * sample_rate)
        shape = envelope(length, 0.085)
        out = [0.0] * length
        phase = 0.0
        for index in range(length):
            progress = index * inv_rate
            freq = 45.0 + 115.0 * math.exp(-progress / 0.028)
            phase += freq * inv_rate
            out[index] = math.sin(tau * phase) * shape[index]
        click = int(0.002 * sample_rate)
        for index in range(click):
            out[index] += rng.uniform(-0.35, 0.35) * (1.0 - index / click)
    elif voice == "snare":
        length = int(0.22 * sample_rate)
        noise_shape = envelope(length, 0.055)
        tone_shape = envelope(length, 0.035)
        out = [0.0] * length
        low = 0.0
        high = 0.0
        previous = 0.0
        for index in range(length):
            white = rng.uniform(-1.0, 1.0)
            low += 0.35 * (white - low)                      # tame the very top
            high = 0.92 * (high + low - previous)            # cut the very bottom
            previous = low
            out[index] = high * noise_shape[index] * 0.85
            out[index] += math.sin(tau * 185.0 * index * inv_rate) * tone_shape[index] * 0.45
    elif voice == "hat":
        length = int(0.06 * sample_rate)
        shape = envelope(length, 0.014)
        out = [0.0] * length
        high = 0.0
        previous = 0.0
        for index in range(length):
            white = rng.uniform(-1.0, 1.0)
            high = 0.72 * (high + white - previous)
            previous = white
            out[index] = high * shape[index] * 0.7
    elif voice == "tom":
        length = int(0.26 * sample_rate)
        shape = envelope(length, 0.075)
        out = [0.0] * length
        phase = 0.0
        for index in range(length):
            freq = 110.0 + 120.0 * math.exp(-index * inv_rate / 0.05)
            phase += freq * inv_rate
            out[index] = math.sin(tau * phase) * shape[index] * 0.9
    else:  # clap
        length = int(0.20 * sample_rate)
        out = [0.0] * length
        bursts = [0.0, 0.009, 0.018]
        high = 0.0
        previous = 0.0
        for index in range(length):
            progress = index * inv_rate
            amplitude = math.exp(-progress / 0.09) * 0.45
            for offset in bursts:
                if 0.0 <= progress - offset < 0.006:
                    amplitude += 0.9
            white = rng.uniform(-1.0, 1.0)
            high = 0.85 * (high + white - previous)
            previous = white
            out[index] = high * amplitude * 0.5
    # Every one-shot ends on an exact zero so a hit near the loop end cannot click.
    fade = min(len(out) // 4, int(0.004 * sample_rate))
    for index in range(fade):
        out[len(out) - 1 - index] *= index / fade
    return out


# --- finalising -------------------------------------------------------------

def finalise(buses: list[list[float]], channels: int, sample_rate: int,
             peak_db: float, master_volume: float) -> tuple[list[float], float, float]:
    peak = 0.0
    for bus in buses:
        peak = max(peak, max(bus), -min(bus))
    if peak <= 1e-9:
        raise SongError("the song rendered digital silence - check that at least one track has notes "
                        "other than \".\" and that volume is above 0")
    gain = (10.0 ** (peak_db / 20.0)) / peak * master_volume
    # Remove DC by subtracting each bus's mean. The buffer IS one period of a
    # periodic signal, so its mean is exactly its DC component: no filter, no
    # start-up transient, and nothing that could disturb the loop seam.
    buses = [_offset(bus, -sum(bus) / len(bus), gain) for bus in buses]

    seam_before = max(abs(bus[0] - bus[-1]) for bus in buses)
    fix = min(len(buses[0]) // 4, max(1, int(SEAM_FIX_MS * sample_rate / 1000.0)))
    for bus in buses:
        step = bus[0] - bus[-1]
        if abs(step) <= 1e-6:
            continue
        # Bleed the remaining discontinuity away over the last two milliseconds
        # instead of fading the whole loop out: inaudible, and the seam becomes
        # continuous rather than merely quiet.
        base = len(bus) - fix
        for index in range(fix):
            bus[base + index] += step * (index + 1) / fix
    seam_after = max(abs(bus[0] - bus[-1]) for bus in buses)

    if channels == 1:
        return buses[0], seam_before, seam_after
    interleaved = [0.0] * (len(buses[0]) * 2)
    interleaved[0::2] = buses[0]
    interleaved[1::2] = buses[1]
    return interleaved, seam_before, seam_after


if __name__ == "__main__":
    raise SystemExit(main())
