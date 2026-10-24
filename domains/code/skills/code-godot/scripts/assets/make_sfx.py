#!/usr/bin/env python3
"""sfxr-style sound-effect synthesizer: presets or raw parameters -> 16-bit PCM WAV.

An agent building a game has no sound source and cannot hear the result, so this
tool is built around three promises:

- **Recognisable by construction.** Each preset is a documented set of DSP
  parameters (waveform, frequency slide, arpeggio steps, ADSR, filters) chosen so
  that "coin" *is* a two-step rising square arpeggio and "laser" *is* a falling
  saw sweep. Nothing is sampled, nothing is random-searched.
- **Verifiable as text.** Every written file is reported with the same numbers
  ``inspect_audio`` measures (peak/RMS dBFS, DC offset, clipping ratio, leading
  and trailing silence, an ASCII envelope) plus the pitch contour the synthesizer
  used, and an ``expect`` block that can be pasted straight into ``inspect_audio``.
- **Deterministic.** ``--seed`` fixes every random decision *and* the small
  pitch/decay jitter applied to each render, so the same seed is byte-identical
  and a different seed is a sibling sound rather than a different sound.

Nothing outside the standard library is used, and nothing is written until the
whole render succeeded.

Examples::

    python3 make_sfx.py --list-presets
    python3 make_sfx.py --preset coin --out /abs/project/audio/coin.wav
    python3 make_sfx.py --preset explosion --seed 7 --variations 3 --out /abs/project/audio/
    python3 make_sfx.py --params '{"wave":"square","freq_start":220,"freq_end":880,
                                   "attack":0.01,"decay":0.1,"release":0.1}' \\
                        --name swoop --out /abs/project/audio/
"""
from __future__ import annotations

import argparse
import array
import json
import math
import random
import struct
import sys
from pathlib import Path

# --- parameter schema -------------------------------------------------------
# Every key a sound can carry, with its default. A key not in here is rejected
# (with the nearest real name), because a silently ignored parameter is the
# difference between "my laser does not sweep" and a two-minute fix.
WAVES = ("square", "saw", "triangle", "sine", "noise")

DEFAULT_PARAMS: dict[str, object] = {
    "wave": "square",            # square | saw | triangle | sine | noise
    "duty": 0.5,                 # square pulse width, 0.01-0.99
    "duty_sweep": 0.0,           # added to duty across the whole sound
    "freq_start": 440.0,         # Hz at t=0
    "freq_end": None,            # Hz at the end; None = no slide
    "freq_curve": "exp",         # exp (musical, log-linear) | linear
    "vibrato_depth": 0.0,        # semitones of pitch wobble
    "vibrato_rate": 0.0,         # wobble speed in Hz
    "arpeggio": [],              # [{"at": 0.25, "semitones": 5}, ...] or [0, 5, 12]
    "attack": 0.005,             # seconds
    "decay": 0.06,               # seconds, peak -> sustain_level
    "sustain": 0.0,              # seconds held at sustain_level
    "sustain_level": 0.6,        # 0-1
    "release": 0.08,             # seconds, sustain_level -> 0
    "punch": 0.0,                # extra gain at the attack peak, gone by end of decay
    "noise_level": 0.0,          # 0-1 white noise mixed into the oscillator
    "sub_level": 0.0,            # 0-1 sine layer under the oscillator (body/thump)
    "sub_freq_start": 120.0,
    "sub_freq_end": 45.0,
    "sub_decay": 0.35,           # fraction of the total duration the sub lasts
    "lowpass": None,             # Hz, 2-pole; None = off
    "lowpass_sweep": 1.0,        # cutoff multiplier across the sound (exp)
    "highpass": None,            # Hz, 1-pole; None = off
    "bitcrush_bits": 0,          # quantise to 2^bits levels; 0 = off
    "bitcrush_rate": 0,          # sample-and-hold rate in Hz; 0 = off
    "repeat": 1,                 # retrigger the whole sound N times inside the duration
}

NUMERIC_RANGES: dict[str, tuple[float, float]] = {
    "duty": (0.01, 0.99),
    "duty_sweep": (-0.98, 0.98),
    "freq_start": (1.0, 20000.0),
    "freq_end": (1.0, 20000.0),
    "vibrato_depth": (0.0, 48.0),
    "vibrato_rate": (0.0, 200.0),
    "attack": (0.0, 10.0),
    "decay": (0.0, 10.0),
    "sustain": (0.0, 10.0),
    "sustain_level": (0.0, 1.0),
    "release": (0.0, 10.0),
    "punch": (0.0, 4.0),
    "noise_level": (0.0, 1.0),
    "sub_level": (0.0, 4.0),
    "sub_freq_start": (1.0, 20000.0),
    "sub_freq_end": (1.0, 20000.0),
    "sub_decay": (0.01, 1.0),
    "lowpass": (20.0, 20000.0),
    "lowpass_sweep": (0.01, 100.0),
    "highpass": (5.0, 20000.0),
    "bitcrush_bits": (0, 16),
    "bitcrush_rate": (0, 44100),
    "repeat": (1, 16),
}

# --- presets ----------------------------------------------------------------
# duration_bounds is the [min, max] the render is expected to land in; it is
# printed with the preset and copied into the file's `expect` block, so
# `inspect_audio` can gate on it without the caller inventing a number.
PRESETS: dict[str, dict] = {
    "coin": {
        "description": "Two-step rising square arpeggio with a bright held tail - the pickup jingle.",
        "duration_bounds": [0.25, 0.70],
        "pitch_direction": "flat",
        "params": {"wave": "square", "duty": 0.5, "freq_start": 987.77,
                   "arpeggio": [{"at": 0.12, "semitones": 5}],
                   "attack": 0.001, "decay": 0.02, "sustain": 0.11, "sustain_level": 0.95,
                   "release": 0.28},
    },
    "jump": {
        "description": "Rising square slide - short, springy, upward.",
        "duration_bounds": [0.08, 0.40],
        "pitch_direction": "rising",
        "params": {"wave": "square", "duty": 0.4, "freq_start": 180.0, "freq_end": 640.0,
                   "attack": 0.002, "decay": 0.0, "sustain": 0.10, "sustain_level": 1.0,
                   "release": 0.07},
    },
    "laser": {
        "description": "Falling saw sweep through a closing lowpass - the classic pew.",
        "duration_bounds": [0.08, 0.40],
        "pitch_direction": "falling",
        "params": {"wave": "saw", "freq_start": 1400.0, "freq_end": 220.0,
                   "attack": 0.0, "decay": 0.05, "sustain": 0.05, "sustain_level": 0.7,
                   "release": 0.09, "lowpass": 6000.0, "lowpass_sweep": 0.25},
    },
    "shoot": {
        "description": "Short falling square with a noise edge - a light weapon.",
        "duration_bounds": [0.05, 0.30],
        "pitch_direction": "falling",
        "params": {"wave": "square", "duty": 0.3, "freq_start": 900.0, "freq_end": 160.0,
                   "noise_level": 0.25, "attack": 0.0, "decay": 0.04, "sustain": 0.02,
                   "sustain_level": 0.6, "release": 0.07, "lowpass": 5000.0,
                   "lowpass_sweep": 0.4},
    },
    "explosion": {
        "description": "Low-passed noise with punch and a long decay over a dropping sine sub.",
        "duration_bounds": [0.50, 1.20],
        "pitch_direction": "none",
        "params": {"wave": "noise", "attack": 0.001, "decay": 0.25, "sustain": 0.14,
                   "sustain_level": 0.55, "release": 0.42, "punch": 0.7,
                   "sub_level": 0.65, "sub_freq_start": 120.0, "sub_freq_end": 38.0,
                   "sub_decay": 0.5, "lowpass": 900.0, "lowpass_sweep": 0.22},
    },
    "hit": {
        "description": "Very short bright noise burst plus a low thump - an impact.",
        "duration_bounds": [0.05, 0.30],
        "pitch_direction": "none",
        "params": {"wave": "noise", "attack": 0.0, "decay": 0.05, "sustain": 0.0,
                   "sustain_level": 0.3, "release": 0.08, "punch": 0.5,
                   "sub_level": 0.7, "sub_freq_start": 210.0, "sub_freq_end": 70.0,
                   "sub_decay": 0.6, "lowpass": 2600.0, "lowpass_sweep": 0.5},
    },
    "hurt": {
        "description": "Falling gritty square with noise and a low body - taking damage.",
        "duration_bounds": [0.10, 0.50],
        "pitch_direction": "falling",
        "params": {"wave": "square", "duty": 0.35, "freq_start": 300.0, "freq_end": 115.0,
                   "noise_level": 0.35, "attack": 0.0, "decay": 0.07, "sustain": 0.05,
                   "sustain_level": 0.55, "release": 0.16, "punch": 0.3,
                   "sub_level": 0.4, "sub_freq_start": 150.0, "sub_freq_end": 60.0,
                   "sub_decay": 0.7, "lowpass": 3200.0, "lowpass_sweep": 0.45},
    },
    "powerup": {
        "description": "Four-step rising arpeggio with vibrato on the held top note.",
        "duration_bounds": [0.30, 1.00],
        "pitch_direction": "rising",
        "params": {"wave": "square", "duty": 0.5, "freq_start": 392.0,
                   "arpeggio": [0, 4, 7, 12],
                   "vibrato_depth": 0.35, "vibrato_rate": 14.0,
                   "attack": 0.004, "decay": 0.03, "sustain": 0.34, "sustain_level": 0.85,
                   "release": 0.20},
    },
    "pickup": {
        "description": "Two-step rising blip - a small collectible.",
        "duration_bounds": [0.08, 0.45],
        "pitch_direction": "rising",
        "params": {"wave": "square", "duty": 0.25, "freq_start": 659.26,
                   "arpeggio": [{"at": 0.35, "semitones": 7}],
                   "attack": 0.001, "decay": 0.02, "sustain": 0.07, "sustain_level": 0.85,
                   "release": 0.12},
    },
    "blip": {
        "description": "Flat short square tick - cursor movement, typewriter text.",
        "duration_bounds": [0.02, 0.15],
        "pitch_direction": "flat",
        "params": {"wave": "square", "duty": 0.5, "freq_start": 880.0,
                   "attack": 0.001, "decay": 0.012, "sustain": 0.018, "sustain_level": 0.7,
                   "release": 0.03},
    },
    "select": {
        "description": "Thin flat square click, lower than blip - menu highlight.",
        "duration_bounds": [0.02, 0.15],
        "pitch_direction": "flat",
        "params": {"wave": "square", "duty": 0.2, "freq_start": 659.26,
                   "attack": 0.001, "decay": 0.015, "sustain": 0.025, "sustain_level": 0.6,
                   "release": 0.035},
    },
    "confirm": {
        "description": "Rising two-note tone - accept / OK. Pitch goes UP.",
        "duration_bounds": [0.10, 0.40],
        "pitch_direction": "rising",
        "params": {"wave": "square", "duty": 0.5, "freq_start": 523.25,
                   "arpeggio": [{"at": 0.42, "semitones": 7}],
                   "attack": 0.003, "decay": 0.02, "sustain": 0.11, "sustain_level": 0.8,
                   "release": 0.10},
    },
    "cancel": {
        "description": "Falling two-note tone - back / dismiss. Pitch goes DOWN.",
        "duration_bounds": [0.10, 0.40],
        "pitch_direction": "falling",
        "params": {"wave": "square", "duty": 0.5, "freq_start": 523.25,
                   "arpeggio": [{"at": 0.42, "semitones": -7}],
                   "attack": 0.003, "decay": 0.02, "sustain": 0.09, "sustain_level": 0.75,
                   "release": 0.10},
    },
    "error": {
        "description": "Low buzzing falling square, repeated twice - rejected input.",
        "duration_bounds": [0.15, 0.60],
        "pitch_direction": "flat",
        "params": {"wave": "square", "duty": 0.15, "freq_start": 220.0, "freq_end": 150.0,
                   "repeat": 2, "bitcrush_bits": 6,
                   "attack": 0.002, "decay": 0.03, "sustain": 0.07, "sustain_level": 0.8,
                   "release": 0.05},
    },
    "footstep": {
        "description": "Tiny filtered noise tap - one step on a hard floor.",
        "duration_bounds": [0.02, 0.15],
        "pitch_direction": "none",
        "params": {"wave": "noise", "attack": 0.001, "decay": 0.025, "sustain": 0.0,
                   "sustain_level": 0.25, "release": 0.03, "punch": 0.4,
                   "lowpass": 1400.0, "lowpass_sweep": 0.5, "highpass": 200.0},
    },
    "door": {
        "description": "Slow low saw creak with heavy vibrato - a door or lever.",
        "duration_bounds": [0.30, 1.10],
        "pitch_direction": "falling",
        "params": {"wave": "saw", "freq_start": 150.0, "freq_end": 92.0,
                   "vibrato_depth": 0.9, "vibrato_rate": 7.0,
                   "attack": 0.04, "decay": 0.10, "sustain": 0.22, "sustain_level": 0.6,
                   "release": 0.18, "lowpass": 1400.0, "lowpass_sweep": 0.6},
    },
    "land": {
        "description": "Soft low thump - landing after a fall.",
        "duration_bounds": [0.06, 0.45],
        "pitch_direction": None,
        "params": {"wave": "noise", "attack": 0.001, "decay": 0.06, "sustain": 0.0,
                   "sustain_level": 0.2, "release": 0.10, "punch": 0.5,
                   "sub_level": 0.9, "sub_freq_start": 130.0, "sub_freq_end": 48.0,
                   "sub_decay": 0.7, "lowpass": 800.0, "lowpass_sweep": 0.4},
    },
    "dash": {
        "description": "Noise whoosh: the lowpass opens then closes again.",
        "duration_bounds": [0.12, 0.60],
        "pitch_direction": "none",
        "params": {"wave": "noise", "attack": 0.06, "decay": 0.07, "sustain": 0.04,
                   "sustain_level": 0.7, "release": 0.12,
                   "lowpass": 600.0, "lowpass_sweep": 6.0, "highpass": 300.0},
    },
    "splash": {
        "description": "Bright noise with a closing lowpass and a long tail - water.",
        "duration_bounds": [0.25, 0.90],
        "pitch_direction": "none",
        "params": {"wave": "noise", "attack": 0.004, "decay": 0.12, "sustain": 0.08,
                   "sustain_level": 0.5, "release": 0.30, "punch": 0.3,
                   "highpass": 700.0, "lowpass": 7000.0, "lowpass_sweep": 0.18},
    },
    "alarm": {
        "description": "Three repeats of a rising two-tone square - warning siren.",
        "duration_bounds": [0.40, 1.50],
        "pitch_direction": "falling",
        "params": {"wave": "square", "duty": 0.5, "freq_start": 659.26,
                   "arpeggio": [{"at": 0.5, "semitones": 5}], "repeat": 3,
                   "attack": 0.004, "decay": 0.01, "sustain": 0.20, "sustain_level": 0.9,
                   "release": 0.06},
    },
}

# --- constants --------------------------------------------------------------
DEFAULT_SAMPLE_RATE = 44100
DEFAULT_PEAK_DB = -1.0
# Every render is faded in and out over this long, so no file can ever start or
# end on a non-zero sample (the cheapest and most common source of clicks).
EDGE_RAMP_MS = 2.0
# DC blocker corner. Low enough to leave a 40 Hz explosion sub alone, high enough
# that an asymmetric pulse wave reports dc_offset ~ 0.
DC_BLOCK_HZ = 20.0
SILENCE_THRESHOLD_DB = -60.0
ENVELOPE_RAMP = " .:-=+*#%@"
ENVELOPE_COLUMNS = 48
ENVELOPE_FLOOR_DB = -60.0
# Jitter applied to every render from the seed, so two seeds are never the same
# file; `--variations` widens it to "audibly different, same family".
BASE_JITTER_SEMITONES = 0.6
BASE_JITTER_TIME = 0.05
VARIATION_JITTER_SEMITONES = 2.0
VARIATION_JITTER_TIME = 0.18
VARIATION_JITTER_DUTY = 0.06


class SfxError(Exception):
    """A user-facing failure: printed to stderr, exit code 1."""


# --- CLI --------------------------------------------------------------------

def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Synthesize sfxr-style game sound effects as 16-bit PCM WAV files.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="Run --list-presets to see every preset's parameters; copy one into --params and edit it.",
    )
    parser.add_argument("--preset", help="Preset name. See --list-presets.")
    parser.add_argument("--params", help="JSON object of synthesis parameters, merged over the preset (or over the defaults).")
    parser.add_argument("--params-file", help="File holding the same JSON object as --params.")
    parser.add_argument("--name", help="Output stem when no --preset is given (default: \"sfx\").")
    parser.add_argument("--out", help="Output .wav file, or a directory to write into (default: <name>.wav in the current directory).")
    parser.add_argument("--seed", type=int, default=0, help="Random seed: fixes the noise and the per-render jitter (default: 0).")
    parser.add_argument("--variations", type=int, default=0,
                        help="Write N sibling files name_1.wav .. name_N.wav with audible pitch/decay jitter.")
    parser.add_argument("--duration", type=float, help="Scale the ADSR so the whole sound lasts this many seconds.")
    parser.add_argument("--volume", type=float, default=1.0, help="Linear gain applied after normalisation, 0-1 (default: 1.0).")
    parser.add_argument("--peak-db", type=float, default=DEFAULT_PEAK_DB,
                        help="Normalisation target for the loudest sample, in dBFS (default: -1.0).")
    parser.add_argument("--sample-rate", type=int, default=DEFAULT_SAMPLE_RATE, help="Sample rate in Hz (default: 44100).")
    parser.add_argument("--overwrite", action="store_true", default=True, help="Overwrite existing files (default).")
    parser.add_argument("--no-overwrite", dest="overwrite", action="store_false",
                        help="Fail instead of overwriting an existing file.")
    parser.add_argument("--list-presets", action="store_true", help="Print every preset with its parameters and exit.")
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
        return list_presets()

    params, name, bounds, direction = resolve_params(args)
    if args.sample_rate < 4000 or args.sample_rate > 192000:
        raise SfxError(f"--sample-rate must be between 4000 and 192000; got {args.sample_rate}")
    if args.duration is not None and not 0.005 <= args.duration <= 30.0:
        raise SfxError(f"--duration must be between 0.005 and 30 seconds; got {args.duration}")
    if not 0.0 < args.volume <= 1.0:
        raise SfxError(f"--volume must be greater than 0 and at most 1; got {args.volume}")
    if args.peak_db > 0.0 or args.peak_db < -60.0:
        raise SfxError(f"--peak-db must be between -60 and 0 (dBFS); got {args.peak_db}")
    if args.variations < 0 or args.variations > 64:
        raise SfxError(f"--variations must be between 0 and 64; got {args.variations}")

    targets = resolve_outputs(args.out, name, args.variations)
    if not args.overwrite:
        existing = [str(path) for path in targets if path.exists()]
        if existing:
            raise SfxError("refusing to overwrite (drop --no-overwrite or pick another --out): " + ", ".join(existing))

    rendered = []
    for index, target in enumerate(targets):
        variation = index + 1 if args.variations else 0
        jittered = apply_jitter(params, args.seed, variation)
        samples = render(jittered, args.sample_rate, args.seed * 1_000_003 + variation,
                         duration_override=args.duration)
        samples = normalise(samples, args.peak_db, args.volume, args.sample_rate)
        rendered.append((target, samples, jittered, variation))

    files = []
    for target, samples, jittered, variation in rendered:
        target.parent.mkdir(parents=True, exist_ok=True)
        write_wav(target, samples, args.sample_rate)
        summary = analyse(samples, args.sample_rate)
        summary["path"] = str(target)
        summary["variation"] = variation
        summary["pitch_start_hz"] = round(pitch_at(jittered, 0.0), 2)
        summary["pitch_end_hz"] = round(pitch_at(jittered, 1.0), 2)
        summary["pitch_direction"] = pitch_direction(summary["pitch_start_hz"], summary["pitch_end_hz"])
        gates = {
            "not_silent": True,
            "no_clipping": True,
            "min_duration": bounds[0],
            "max_duration": bounds[1],
        }
        # Only for presets whose measured contour held across five seeds; a
        # gate that flakes is worse than no gate.
        if direction is not None:
            gates["pitch_direction"] = direction
        summary["expect"] = gates
        files.append(summary)

    return {
        "ok": True,
        "counts": {"files": len(files)},
        "preset": args.preset,
        "name": name,
        "seed": args.seed,
        "sample_rate": args.sample_rate,
        "duration_bounds": bounds,
        "pitch_direction": direction,
        "params": params,
        "needs_import": True,
        "files": files,
    }


def list_presets() -> dict:
    presets = {}
    for key in sorted(PRESETS):
        entry = PRESETS[key]
        merged = dict(DEFAULT_PARAMS)
        merged.update(entry["params"])
        presets[key] = {
            "description": entry["description"],
            "duration_bounds": entry["duration_bounds"],
            "pitch_direction": entry["pitch_direction"],
            "nominal_duration_s": round(nominal_duration(merged), 4),
            "params": entry["params"],
            "full_params": merged,
        }
    return {
        "ok": True,
        "counts": {"presets": len(presets)},
        "waves": list(WAVES),
        "param_defaults": DEFAULT_PARAMS,
        "usage": "make_sfx.py --preset <name> --out DIR_OR_FILE [--seed N] [--variations N]",
        "presets": presets,
    }


def resolve_params(args: argparse.Namespace) -> tuple[dict, str, list[float], str | None]:
    params = dict(DEFAULT_PARAMS)
    name = args.name or "sfx"
    bounds = [0.005, 30.0]
    direction = None
    if args.preset:
        if args.preset not in PRESETS:
            raise SfxError(
                f"unknown preset {args.preset!r}{nearest(args.preset, PRESETS)}. "
                f"Presets: {', '.join(sorted(PRESETS))}. Run --list-presets for their parameters."
            )
        preset = PRESETS[args.preset]
        params.update(preset["params"])
        name = args.name or args.preset
        bounds = list(preset["duration_bounds"])
        direction = preset["pitch_direction"]
    overrides: dict = {}
    if args.params_file:
        path = Path(args.params_file).expanduser()
        if not path.is_file():
            raise SfxError(f"--params-file does not exist: {path}")
        overrides.update(load_json(path.read_text(encoding="utf-8"), f"--params-file {path}"))
    if args.params:
        overrides.update(load_json(args.params, "--params"))
    if overrides:
        for key in overrides:
            if key not in DEFAULT_PARAMS:
                raise SfxError(
                    f"unknown sound parameter {key!r}{nearest(key, DEFAULT_PARAMS)}. "
                    f"Parameters: {', '.join(sorted(DEFAULT_PARAMS))}"
                )
        params.update(overrides)
        # Edited parameters invalidate the preset's measured contour, and a
        # hand-written sound never had documented bounds to begin with.
        direction = None
        if not args.preset:
            bounds = [0.005, 30.0]
    validate_params(params)
    if args.duration is not None:
        bounds = [round(args.duration * 0.9, 4), round(args.duration * 1.1 + 0.01, 4)]
    return params, name, bounds, direction


def load_json(text: str, label: str) -> dict:
    try:
        value = json.loads(text)
    except json.JSONDecodeError as error:
        raise SfxError(f"{label} is not valid JSON: {error}") from error
    if not isinstance(value, dict):
        raise SfxError(f"{label} must be a JSON object of parameters, e.g. '{{\"wave\":\"saw\"}}'")
    return value


def validate_params(params: dict) -> None:
    wave = params["wave"]
    if wave not in WAVES:
        raise SfxError(f"unknown wave {wave!r}{nearest(str(wave), dict.fromkeys(WAVES))}. Waves: {', '.join(WAVES)}")
    curve = params["freq_curve"]
    if curve not in ("exp", "linear"):
        raise SfxError(f"freq_curve must be \"exp\" or \"linear\"; got {curve!r}")
    for key, (low, high) in NUMERIC_RANGES.items():
        value = params.get(key)
        if value is None:
            continue
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            raise SfxError(f"{key} must be a number; got {value!r}")
        if not low <= float(value) <= high:
            raise SfxError(f"{key} must be between {low} and {high}; got {value}")
    params["repeat"] = int(params["repeat"])
    params["bitcrush_bits"] = int(params["bitcrush_bits"])
    params["bitcrush_rate"] = int(params["bitcrush_rate"])
    params["arpeggio"] = normalise_arpeggio(params["arpeggio"])
    if nominal_duration(params) <= 0.002:
        raise SfxError("attack + decay + sustain + release is ~0; give the sound a length "
                       "(for example \"decay\": 0.05, \"release\": 0.1)")


def normalise_arpeggio(raw: object) -> list[dict]:
    if raw in (None, [], ()):
        return []
    if not isinstance(raw, (list, tuple)):
        raise SfxError('arpeggio must be a list, e.g. [0, 4, 7] or [{"at": 0.25, "semitones": 5}]')
    steps: list[dict] = []
    plain = [item for item in raw if isinstance(item, (int, float)) and not isinstance(item, bool)]
    if len(plain) == len(raw):
        # [0, 4, 7, 12] -> equal steps across the sound.
        count = len(plain)
        for index, semitones in enumerate(plain):
            steps.append({"at": round(index / count, 6), "semitones": float(semitones)})
        return steps
    for index, item in enumerate(raw):
        if not isinstance(item, dict):
            raise SfxError(f'arpeggio[{index}] must be a number or {{"at": 0-1, "semitones": N}}; got {item!r}')
        unknown = set(item) - {"at", "semitones"}
        if unknown:
            raise SfxError(f'arpeggio[{index}] has unknown keys {sorted(unknown)}; allowed: "at", "semitones"')
        at = float(item.get("at", 0.0))
        if not 0.0 <= at <= 1.0:
            raise SfxError(f'arpeggio[{index}]["at"] is a fraction of the sound, 0-1; got {at}')
        steps.append({"at": at, "semitones": float(item.get("semitones", 0.0))})
    steps.sort(key=lambda step: step["at"])
    return steps


def nearest(name: str, candidates) -> str:
    import difflib

    close = difflib.get_close_matches(name, list(candidates), n=3, cutoff=0.5)
    return f" (did you mean {', '.join(close)}?)" if close else ""


def resolve_outputs(out: str | None, name: str, variations: int) -> list[Path]:
    count = max(1, variations)
    if out is None:
        base_dir, stem = Path.cwd(), name
    else:
        path = Path(out).expanduser()
        if path.suffix.lower() == ".wav":
            base_dir, stem = path.parent, path.stem
        else:
            base_dir, stem = path, name
    base_dir = base_dir if base_dir != Path("") else Path.cwd()
    if variations:
        return [base_dir / f"{stem}_{index + 1}.wav" for index in range(count)]
    return [base_dir / f"{stem}.wav"]


# --- synthesis --------------------------------------------------------------

def nominal_duration(params: dict) -> float:
    one = (float(params["attack"]) + float(params["decay"])
           + float(params["sustain"]) + float(params["release"]))
    return one * max(1, int(params["repeat"]))


def apply_jitter(params: dict, seed: int, variation: int) -> dict:
    """Pitch/decay jitter derived from the seed.

    Always applied (so two seeds never produce the same bytes) but tiny; with
    ``--variations`` the spread widens to "you can hear these apart, they are
    still the same sound".
    """
    jittered = dict(params)
    # Seeded with a string, not a tuple: Python 3.14 rejects tuple seeds.
    rng = random.Random("jitter:%d:%d" % (seed, variation))
    if variation:
        semitones = rng.uniform(-VARIATION_JITTER_SEMITONES, VARIATION_JITTER_SEMITONES)
        time_scale = 1.0 + rng.uniform(-VARIATION_JITTER_TIME, VARIATION_JITTER_TIME)
        duty_shift = rng.uniform(-VARIATION_JITTER_DUTY, VARIATION_JITTER_DUTY)
    else:
        semitones = rng.uniform(-BASE_JITTER_SEMITONES, BASE_JITTER_SEMITONES)
        time_scale = 1.0 + rng.uniform(-BASE_JITTER_TIME, BASE_JITTER_TIME)
        duty_shift = 0.0
    ratio = 2.0 ** (semitones / 12.0)
    for key in ("freq_start", "freq_end", "sub_freq_start", "sub_freq_end"):
        if jittered.get(key) is not None:
            low, high = NUMERIC_RANGES[key]
            jittered[key] = min(high, max(low, float(jittered[key]) * ratio))
    for key in ("decay", "sustain", "release"):
        low, high = NUMERIC_RANGES[key]
        jittered[key] = min(high, max(low, float(jittered[key]) * time_scale))
    if duty_shift:
        low, high = NUMERIC_RANGES["duty"]
        jittered["duty"] = min(high, max(low, float(jittered["duty"]) + duty_shift))
    jittered["_jitter"] = {"semitones": round(semitones, 4), "time_scale": round(time_scale, 4)}
    return jittered


def pitch_at(params: dict, progress: float) -> float:
    """The oscillator frequency the synthesizer uses at `progress` (0-1).

    Exposed because a model cannot hear whether "jump" rises: the number is read
    off the same code path the renderer uses, and `inspect_audio` measures the
    rendered file independently, so the two can be compared.
    """
    if params["wave"] == "noise":
        return 0.0
    start = float(params["freq_start"])
    end = params["freq_end"]
    # Inside one repeat the slide runs start -> end; `progress` is the position
    # within a single repetition.
    if end is None:
        base = start
    elif params["freq_curve"] == "linear":
        base = start + (float(end) - start) * progress
    else:
        base = start * (float(end) / start) ** progress
    semitones = 0.0
    for step in params["arpeggio"]:
        if progress + 1e-9 >= step["at"]:
            semitones = step["semitones"]
    return base * (2.0 ** (semitones / 12.0))


def pitch_direction(start_hz: float, end_hz: float) -> str:
    if start_hz <= 0.0 or end_hz <= 0.0:
        return "none"
    ratio = end_hz / start_hz
    if ratio > 1.03:
        return "rising"
    if ratio < 0.97:
        return "falling"
    return "flat"


def render(params: dict, sample_rate: int, seed: int, duration_override: float | None) -> list[float]:
    total = nominal_duration(params)
    scale = 1.0 if duration_override is None else duration_override / total
    repeats = max(1, int(params["repeat"]))
    one = total / repeats * scale
    frames_each = max(2, int(round(one * sample_rate)))
    rng = random.Random(seed)

    out: list[float] = []
    for _ in range(repeats):
        out.extend(_render_once(params, sample_rate, rng, frames_each, scale))
    return out


def _render_once(params: dict, sample_rate: int, rng: random.Random,
                 frames: int, scale: float) -> list[float]:
    wave = params["wave"]
    duty0 = float(params["duty"])
    duty_sweep = float(params["duty_sweep"])
    curve_exp = params["freq_curve"] == "exp"
    f0 = float(params["freq_start"])
    f1 = params["freq_end"]
    f1 = f0 if f1 is None else float(f1)
    vib_depth = float(params["vibrato_depth"])
    vib_rate = float(params["vibrato_rate"])
    arpeggio = params["arpeggio"]
    noise_level = float(params["noise_level"])
    sub_level = float(params["sub_level"])
    sub_f0 = float(params["sub_freq_start"])
    sub_f1 = float(params["sub_freq_end"])
    sub_span = max(1, int(frames * float(params["sub_decay"])))

    envelope = _adsr(params, frames, scale)

    lowpass = params["lowpass"]
    lowpass_sweep = float(params["lowpass_sweep"])
    highpass = params["highpass"]
    crush_levels = (1 << int(params["bitcrush_bits"])) if int(params["bitcrush_bits"]) else 0
    hold_every = int(round(sample_rate / int(params["bitcrush_rate"]))) if int(params["bitcrush_rate"]) else 0

    inv_rate = 1.0 / sample_rate
    tau = math.tau

    phase = 0.0
    sub_phase = 0.0
    lp1 = lp2 = 0.0
    hp_y = hp_x = 0.0
    held = 0.0
    out = [0.0] * frames
    # Arpeggio steps are frame indices so the inner loop only compares integers.
    arp_frames = [(int(step["at"] * frames), 2.0 ** (step["semitones"] / 12.0)) for step in arpeggio]
    arp_index = 0
    arp_mult = 1.0

    for index in range(frames):
        progress = index / frames
        while arp_index < len(arp_frames) and index >= arp_frames[arp_index][0]:
            arp_mult = arp_frames[arp_index][1]
            arp_index += 1

        if wave == "noise":
            value = rng.uniform(-1.0, 1.0)
        else:
            if f1 == f0:
                freq = f0
            elif curve_exp:
                freq = f0 * (f1 / f0) ** progress
            else:
                freq = f0 + (f1 - f0) * progress
            freq *= arp_mult
            if vib_depth > 0.0 and vib_rate > 0.0:
                freq *= 2.0 ** (vib_depth * math.sin(tau * vib_rate * index * inv_rate) / 12.0)
            phase += freq * inv_rate
            if phase >= 1.0:
                phase -= int(phase)
            if wave == "square":
                duty = duty0 + duty_sweep * progress
                if duty < 0.02:
                    duty = 0.02
                elif duty > 0.98:
                    duty = 0.98
                value = 1.0 if phase < duty else -1.0
            elif wave == "saw":
                value = 1.0 - 2.0 * phase
            elif wave == "triangle":
                value = 4.0 * abs(phase - 0.5) - 1.0
            else:
                value = math.sin(tau * phase)
            if noise_level > 0.0:
                value = value * (1.0 - noise_level) + rng.uniform(-1.0, 1.0) * noise_level

        value *= envelope[index]

        if sub_level > 0.0 and index < sub_span:
            sub_progress = index / sub_span
            sub_freq = sub_f0 * (sub_f1 / sub_f0) ** sub_progress
            sub_phase += sub_freq * inv_rate
            if sub_phase >= 1.0:
                sub_phase -= int(sub_phase)
            # Exponential decay so the thump lands and gets out of the way.
            value += math.sin(tau * sub_phase) * sub_level * math.exp(-4.0 * sub_progress)

        if lowpass is not None:
            cutoff = float(lowpass) * (lowpass_sweep ** progress)
            alpha = 1.0 - math.exp(-tau * min(cutoff, sample_rate * 0.45) * inv_rate)
            lp1 += alpha * (value - lp1)
            lp2 += alpha * (lp1 - lp2)
            value = lp2
        if highpass is not None:
            coefficient = 1.0 / (1.0 + tau * float(highpass) * inv_rate)
            hp_y = coefficient * (hp_y + value - hp_x)
            hp_x = value
            value = hp_y
        if hold_every > 1:
            if index % hold_every == 0:
                held = value
            value = held
        if crush_levels:
            value = round(value * crush_levels) / crush_levels

        out[index] = value
    return out


def _adsr(params: dict, frames: int, _scale: float) -> list[float]:
    """Attack -> (1 + punch), decay -> sustain_level, sustain, release -> 0.

    Stage lengths are the parameter seconds re-expressed as a share of this
    repeat's frame count, so `--duration` stretches the shape instead of
    truncating it. With `decay` 0 the envelope steps straight to sustain_level.
    """
    span = (float(params["attack"]) + float(params["decay"])
            + float(params["sustain"]) + float(params["release"]))
    span = max(span, 1e-9)
    attack = max(0, int(round(float(params["attack"]) * frames / span)))
    decay = max(0, int(round(float(params["decay"]) * frames / span)))
    sustain = max(0, int(round(float(params["sustain"]) * frames / span)))
    release = max(0, frames - attack - decay - sustain)
    level = float(params["sustain_level"])
    peak = 1.0 + float(params["punch"])

    envelope = [0.0] * frames
    index = 0
    current = peak
    for step in range(attack):
        if index >= frames:
            break
        current = peak * (step + 1) / attack
        envelope[index] = current
        index += 1
    for step in range(decay):
        if index >= frames:
            break
        current = peak + (level - peak) * (step + 1) / decay
        envelope[index] = current
        index += 1
    if decay:
        current = level
    elif sustain:
        current = level
    for _ in range(sustain):
        if index >= frames:
            break
        envelope[index] = current
        index += 1
    start = current
    for step in range(release):
        if index >= frames:
            break
        envelope[index] = start * (1.0 - (step + 1) / release)
        index += 1
    return envelope


# --- post-processing --------------------------------------------------------

def normalise(samples: list[float], peak_db: float, volume: float, sample_rate: int) -> list[float]:
    if not samples:
        raise SfxError("the sound rendered zero samples; give it a longer envelope")
    samples = dc_block(samples, sample_rate)
    edge_ramp(samples, sample_rate)
    peak = max(max(samples), -min(samples))
    if peak <= 1e-9:
        raise SfxError("the sound rendered digital silence; check the envelope (attack/decay/sustain/release) "
                       "and that sustain_level or punch is above 0")
    gain = (10.0 ** (peak_db / 20.0)) / peak * volume
    return [value * gain for value in samples]


def dc_block(samples: list[float], sample_rate: int) -> list[float]:
    """One-pole DC blocker: an asymmetric pulse wave otherwise carries a constant
    offset, which wastes headroom and thumps when the sound starts."""
    coefficient = 1.0 - math.tau * DC_BLOCK_HZ / sample_rate
    out = [0.0] * len(samples)
    previous_in = 0.0
    previous_out = 0.0
    for index, value in enumerate(samples):
        previous_out = value - previous_in + coefficient * previous_out
        previous_in = value
        out[index] = previous_out
    return out


def edge_ramp(samples: list[float], sample_rate: int) -> None:
    ramp = min(len(samples) // 2, max(1, int(sample_rate * EDGE_RAMP_MS / 1000.0)))
    for index in range(ramp):
        factor = (index + 1) / (ramp + 1)
        samples[index] *= factor
        samples[len(samples) - 1 - index] *= factor


def write_wav(path: Path, samples: list[float], sample_rate: int, channels: int = 1) -> None:
    """Canonical 44-byte-header PCM WAV. `samples` is interleaved when channels > 1."""
    data = to_pcm16(samples)
    header = b"RIFF" + struct.pack("<I", 36 + len(data)) + b"WAVE"
    header += b"fmt " + struct.pack("<IHHIIHH", 16, 1, channels, sample_rate,
                                    sample_rate * channels * 2, channels * 2, 16)
    header += b"data" + struct.pack("<I", len(data))
    path.write_bytes(header + data)


def to_pcm16(samples: list[float]) -> bytes:
    scaled = array.array("h", (
        32767 if value >= 1.0 else (-32768 if value <= -1.0 else int(round(value * 32767.0)))
        for value in samples
    ))
    if sys.byteorder == "big":
        scaled.byteswap()
    return scaled.tobytes()


# --- analysis (the same numbers inspect_audio reports) ----------------------

def analyse(samples: list[float], sample_rate: int, channels: int = 1) -> dict:
    frames = len(samples) // channels
    peak = max(max(samples), -min(samples)) if samples else 0.0
    total = 0.0
    offset = 0.0
    clipped = 0
    for value in samples:
        total += value * value
        offset += value
        if value >= 0.999969 or value <= -0.999969:
            clipped += 1
    count = max(1, len(samples))
    rms = math.sqrt(total / count)
    leading, trailing = silence_edges(samples, channels)
    return {
        "format": "wav",
        "duration_s": round(frames / sample_rate, 6),
        "sample_rate": sample_rate,
        "channels": channels,
        "bit_depth": 16,
        "frames": frames,
        "peak_db": to_db(peak),
        "rms_db": to_db(rms),
        "silent": peak < 10.0 ** (SILENCE_THRESHOLD_DB / 20.0),
        "clipping_ratio": round(clipped / count, 6),
        "dc_offset": round(offset / count, 6),
        "leading_silence_ms": round(leading / channels / sample_rate * 1000.0, 3),
        "trailing_silence_ms": round(trailing / channels / sample_rate * 1000.0, 3),
        "envelope": envelope_line(samples, channels),
    }


def silence_edges(samples: list[float], channels: int) -> tuple[int, int]:
    threshold = 10.0 ** (SILENCE_THRESHOLD_DB / 20.0)
    leading = 0
    for value in samples:
        if abs(value) >= threshold:
            break
        leading += 1
    if leading == len(samples):
        return len(samples), len(samples)
    trailing = 0
    for value in reversed(samples):
        if abs(value) >= threshold:
            break
        trailing += 1
    return leading, trailing


def to_db(value: float) -> float:
    if value <= 1e-9:
        return -144.0
    return round(20.0 * math.log10(value), 2)


def envelope_line(samples: list[float], channels: int = 1, columns: int = ENVELOPE_COLUMNS) -> str:
    """One ASCII line whose height is the per-slice peak in dB - the shape of the
    sound, readable without hearing it."""
    frames = max(1, len(samples) // channels)
    columns = max(4, min(240, columns))
    last = len(ENVELOPE_RAMP) - 1
    line = []
    for column in range(columns):
        start = column * frames // columns * channels
        stop = max(start + channels, (column + 1) * frames // columns * channels)
        window = samples[start:stop]
        peak = max((abs(value) for value in window), default=0.0)
        if peak <= 1e-9:
            line.append(ENVELOPE_RAMP[0])
            continue
        db = 20.0 * math.log10(peak)
        level = (db - ENVELOPE_FLOOR_DB) / (0.0 - ENVELOPE_FLOOR_DB)
        line.append(ENVELOPE_RAMP[max(0, min(last, int(round(level * last))))])
    return "".join(line)


if __name__ == "__main__":
    raise SystemExit(main())
