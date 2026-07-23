#!/usr/bin/env python3
"""Generate original notification-sound candidates for Tests.

The renderer deliberately uses only Python's standard library. Every sound is
procedural and deterministic, so there are no sample-library dependencies or
redistribution licences to track.
"""

import argparse
import math
import random
import struct
import wave
from pathlib import Path


SAMPLE_RATE = 44_100
SEED = 0x7E575
ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUTPUT = ROOT / "Tests" / "Resources" / "NotificationSounds" / "Candidates"


def seconds(value):
    return max(1, int(round(value * SAMPLE_RATE)))


def silence(duration):
    return [0.0] * seconds(duration)


def mix(destination, source, start=0.0, gain=1.0):
    offset = seconds(start)
    required = offset + len(source)
    if required > len(destination):
        destination.extend([0.0] * (required - len(destination)))
    for index, value in enumerate(source):
        destination[offset + index] += value * gain


def envelope(position, duration, attack, decay, sustain, release, curve=1.0):
    if position < attack:
        value = position / max(attack, 1e-9)
    elif position < attack + decay:
        phase = (position - attack) / max(decay, 1e-9)
        value = 1.0 + (sustain - 1.0) * phase
    elif position < duration - release:
        value = sustain
    else:
        phase = (duration - position) / max(release, 1e-9)
        value = sustain * max(0.0, phase)
    return max(0.0, value) ** curve


def oscillator(
    frequency,
    duration,
    partials,
    attack=0.008,
    decay=0.08,
    sustain=0.42,
    release=0.12,
    vibrato_depth=0.0,
    vibrato_rate=5.2,
    decay_rate=0.0,
):
    output = []
    phases = [0.0 for _ in partials]
    for index in range(seconds(duration)):
        time = index / SAMPLE_RATE
        vibrato = 1.0 + vibrato_depth * math.sin(2.0 * math.pi * vibrato_rate * time)
        sample = 0.0
        for partial_index, (ratio, amplitude) in enumerate(partials):
            phases[partial_index] += 2.0 * math.pi * frequency * ratio * vibrato / SAMPLE_RATE
            partial_decay = math.exp(-decay_rate * time * max(1.0, ratio * 0.45))
            sample += math.sin(phases[partial_index]) * amplitude * partial_decay
        sample *= envelope(time, duration, attack, decay, sustain, release, curve=0.82)
        output.append(sample)
    return output


def filtered_noise(duration, rng, brightness=0.75, decay_rate=16.0):
    output = []
    previous = 0.0
    for index in range(seconds(duration)):
        time = index / SAMPLE_RATE
        raw = rng.uniform(-1.0, 1.0)
        # Interpolate between a soft low-passed texture and a crisp difference signal.
        low = previous * 0.82 + raw * 0.18
        high = raw - previous
        previous = raw
        value = low * (1.0 - brightness) + high * brightness
        output.append(value * math.exp(-decay_rate * time))
    return output


def relay_click(rng, material):
    duration = 0.055 if material != "mechanical" else 0.075
    body = silence(duration)
    brightness = {"warm": 0.38, "glass": 0.86, "mechanical": 0.62}[material]
    if material != "glass":
        mix(body, filtered_noise(duration, rng, brightness=brightness, decay_rate=34.0), gain=0.50)
    resonance = {"warm": 920.0, "glass": 2_450.0, "mechanical": 610.0}[material]
    mix(
        body,
        oscillator(
            resonance,
            duration,
            [(1.0, 1.0), (2.02, 0.22)],
            attack=0.001,
            decay=0.018,
            sustain=0.06,
            release=0.025,
            decay_rate=24.0,
        ),
        gain=0.32,
    )
    return body


PARTIALS = {
    "warm": [(1.0, 1.0), (2.0, 0.24), (3.0, 0.075), (4.0, 0.025)],
    "glass": [(1.0, 1.0), (2.71, 0.31), (4.06, 0.14), (5.43, 0.055)],
    "mechanical": [(1.0, 1.0), (2.0, 0.15), (3.0, 0.23), (5.0, 0.08)],
}


def note(frequency, duration, material, emphasis=1.0):
    if material == "warm":
        signal = oscillator(
            frequency,
            duration,
            PARTIALS[material],
            attack=0.012,
            decay=0.105,
            sustain=0.44,
            release=min(0.14, duration * 0.46),
            vibrato_depth=0.0009,
            decay_rate=1.8,
        )
    elif material == "glass":
        signal = oscillator(
            frequency,
            duration,
            PARTIALS[material],
            attack=0.002,
            decay=0.10,
            sustain=0.20,
            release=min(0.19, duration * 0.55),
            decay_rate=5.0,
        )
    else:
        signal = oscillator(
            frequency,
            duration,
            PARTIALS[material],
            attack=0.003,
            decay=0.055,
            sustain=0.34,
            release=min(0.09, duration * 0.40),
            decay_rate=3.4,
        )
    return [value * emphasis for value in signal]


def add_ambience(signal, material):
    taps = {
        "warm": [(0.052, 0.13), (0.091, 0.065)],
        "glass": [(0.041, 0.17), (0.083, 0.09), (0.127, 0.045)],
        "mechanical": [(0.028, 0.075), (0.061, 0.035)],
    }[material]
    dry = list(signal)
    for delay, gain in taps:
        mix(signal, dry, start=delay, gain=gain)


def finish(signal, duration, target_peak):
    wanted = seconds(duration)
    if len(signal) < wanted:
        signal.extend([0.0] * (wanted - len(signal)))
    else:
        signal = signal[:wanted]

    fade_samples = min(seconds(0.018), len(signal))
    for index in range(fade_samples):
        signal[-fade_samples + index] *= 1.0 - index / fade_samples

    # Gentle saturation controls glass/noise transients before peak matching.
    signal = [math.tanh(value * 1.12) for value in signal]
    peak = max(max(abs(value) for value in signal), 1e-9)
    scale = target_peak / peak
    return [value * scale for value in signal]


def ignition(material, rng):
    output = silence(0.44)
    mix(output, relay_click(rng, material), start=0.018, gain=0.72)
    mix(output, note(523.25, 0.19, material, 0.72), start=0.090)
    mix(output, note(783.99, 0.22, material, 0.68), start=0.205)
    add_ambience(output, material)
    return finish(output, 0.46, 0.48)


def fracture(material, rng):
    output = silence(0.67)
    mix(output, relay_click(rng, material), start=0.012, gain=0.50)
    mix(output, note(783.99, 0.27, material, 0.82), start=0.072)
    mix(output, note(622.25, 0.36, material, 0.92), start=0.225)
    if material != "glass":
        crack = filtered_noise(0.13, rng, brightness=0.91, decay_rate=22.0)
        mix(output, crack, start=0.216, gain=0.20 if material == "warm" else 0.29)
    # A quiet low component gives failure weight without turning it into an alarm.
    mix(
        output,
        oscillator(
            155.56,
            0.30,
            [(1.0, 1.0), (2.0, 0.12)],
            attack=0.008,
            decay=0.07,
            sustain=0.26,
            release=0.16,
            decay_rate=4.0,
        ),
        start=0.235,
        gain=0.20,
    )
    add_ambience(output, material)
    return finish(output, 0.70, 0.59)


def resolved(material, rng):
    output = silence(0.61)
    mix(output, relay_click(rng, material), start=0.014, gain=0.55)
    mix(output, note(523.25, 0.20, material, 0.64), start=0.075)
    mix(output, note(783.99, 0.22, material, 0.66), start=0.190)
    mix(output, note(1046.50, 0.30, material, 0.72), start=0.315)
    # A restrained root underneath the last note makes the cadence feel settled.
    mix(output, note(261.63, 0.24, material, 0.24), start=0.325)
    add_ambience(output, material)
    return finish(output, 0.64, 0.53)


def write_wave(path, samples):
    path.parent.mkdir(parents=True, exist_ok=True)
    frames = bytearray()
    for sample in samples:
        integer = int(round(max(-1.0, min(1.0, sample)) * 32_767))
        frames.extend(struct.pack("<h", integer))
    with wave.open(str(path), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(SAMPLE_RATE)
        output.writeframes(frames)


def generate(output_directory):
    names = {
        "Ignition": ignition,
        "Fracture": fracture,
        "Resolved": resolved,
    }
    generated = []
    for family_index, material in enumerate(("warm", "glass", "mechanical")):
        for sound_index, (name, renderer) in enumerate(names.items()):
            rng = random.Random(SEED + family_index * 100 + sound_index)
            path = output_directory / material / f"Tests-{name}.wav"
            write_wave(path, renderer(material, rng))
            generated.append(path)
    return generated


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output",
        type=Path,
        default=DEFAULT_OUTPUT,
        help=f"output directory (default: {DEFAULT_OUTPUT})",
    )
    arguments = parser.parse_args()
    generated = generate(arguments.output.resolve())
    for path in generated:
        print(path)


if __name__ == "__main__":
    main()
