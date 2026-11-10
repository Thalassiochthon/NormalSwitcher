"""Render the original NormalSwitcher cues as deterministic mono PCM WAV files."""

import math
from pathlib import Path
import random
import struct
import wave


RATE = 44100
OUTPUT = Path(__file__).resolve().parent
RNG = random.Random(131)


def voice(length, start_hz, end_hz, decay, overtones, noise=0):
    """A short damped tone, optionally with a filtered transient."""
    samples = []
    filtered = 0.0
    for i in range(round(length * RATE)):
        t = i / RATE
        phase = 2 * math.pi * (start_hz * t + (end_hz - start_hz) * t * t / (2 * length))
        filtered = 0.55 * filtered + 0.45 * RNG.uniform(-1, 1)
        tone = sum(level * math.sin(ratio * phase) for ratio, level in overtones)
        envelope = min(1, t / 0.003, (length - t) / 0.008) * math.exp(-t / decay)
        samples.append(envelope * (tone + noise * filtered * math.exp(-t / 0.007)))
    return samples


def silence(length):
    return [0.0] * round(length * RATE)


def write(name, samples, peak):
    scale = peak * 32767 / max(map(abs, samples))
    pcm = struct.pack(f"<{len(samples)}h", *(round(s * scale) for s in samples))
    with wave.open(str(OUTPUT / f"{name}.wav"), "wb") as wav:
        wav.setparams((1, 2, RATE, 0, "NONE", "not compressed"))
        wav.writeframes(pcm)


def main():
    basic = [(1, 1.0)]
    tap = voice(0.046, 760, 510, 0.011, [(1, 1), (1.84, 0.19)], noise=0.34)
    write("tap", tap, 0.24)
    write("double", [s * 0.73 for s in tap] + silence(0.025) + tap, 0.24)
    write("wood", voice(0.064, 575, 545, 0.020, [(1, 1), (2.62, 0.38), (4.15, 0.16)], noise=0.18), 0.23)
    write("drop", voice(0.098, 950, 315, 0.038, [(1, 1), (2, 0.12)]), 0.21)
    write("rise", voice(0.089, 430, 920, 0.045, [(1, 1), (2, 0.08)]), 0.20)
    write("glass", voice(0.116, 1150, 1140, 0.036, [(1, 1), (2.14, 0.20), (3.49, 0.11)]), 0.19)
    soft = voice(0.072, 530, 455, 0.034, basic)
    write("soft", soft, 0.16)
    pulse = voice(0.046, 590, 510, 0.016, basic)
    write("pulse", pulse + silence(0.017) + pulse + silence(0.017) + pulse, 0.20)


if __name__ == "__main__":
    main()
