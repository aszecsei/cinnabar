# Writes the sample's generated sounds (see docs/content/kinds/audio.md#the-samples-sounds): 16-bit PCM .wav files that a
# formula makes, so the repository holds no recorded audio. It uses the standard library only, and always writes the same
# bytes. `just sample-audio` runs it; commit what it writes, with the .meta files that the cooker gives them.
import math
import os
import random
import struct
import sys
import wave


def write_wav(path, rate, samples):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    peak = max(abs(s) for s in samples) or 1.0
    with wave.open(path, "wb") as f:
        f.setnchannels(1)
        f.setsampwidth(2)
        f.setframerate(rate)
        f.writeframes(b"".join(struct.pack("<h", int(s / peak * 26000)) for s in samples))


# hum is a machine's drone for a source that moves, 2 seconds that loop. Every part has a whole number of cycles in them,
# so the loop has no seam. Its high harmonics make it easy to hear a wall take them away.
def hum(rate=48000, seconds=2):
    frames = rate * seconds
    # In cycles per loop: 110 Hz and its harmonics, with a slow beat, and a whine at 3 kHz.
    parts = [(220, 1.0), (440, 0.5), (660, 0.35), (1320, 0.2), (2640, 0.12), (6000, 0.08)]
    samples = []
    for i in range(frames):
        t = i / frames * math.tau
        beat = 0.8 + 0.2 * math.sin(t * 6)
        samples.append(beat * sum(gain * math.sin(t * cycles) for cycles, gain in parts))
    return rate, samples


# thud is a short knock for a box that lands: a falling low tone under a burst of noise, gone in 0.4 seconds.
def thud(rate=48000, seconds=0.4):
    frames = int(rate * seconds)
    noise = random.Random(27)
    samples = []
    phase = 0.0
    for i in range(frames):
        t = i / rate
        phase += math.tau * (60 + 90 * math.exp(-t * 30)) / rate
        tone = math.sin(phase) * math.exp(-t * 11)
        burst = (noise.random() * 2 - 1) * math.exp(-t * 70) * 0.5
        samples.append(tone + burst)
    return rate, samples


# ambience is a slow pad, long enough to stream: 20 seconds that loop, at half the engine's rate, so a cook also converts
# its rate. Its chords' parts have whole numbers of cycles in the 20 seconds too.
def ambience(rate=24000, seconds=20):
    frames = rate * seconds
    chords = [
        # Each lasts a quarter of the loop, and fades into the next. In cycles per loop.
        [2200, 2640, 3300, 4400],
        [1960, 2472, 2940, 3920],
        [1746, 2200, 2616, 3492],
        [1960, 2472, 2940, 3920],
    ]
    samples = []
    for i in range(frames):
        u = i / frames
        where = u * len(chords)
        index = int(where)
        blend = 0.5 - 0.5 * math.cos((where - index) * math.pi)
        t = u * math.tau
        value = 0.0
        for weight, chord in ((1 - blend, chords[index]), (blend, chords[(index + 1) % len(chords)])):
            for cycles in chord:
                value += weight * (math.sin(t * cycles) + 0.4 * math.sin(t * (cycles * 2 + 3)))
        swell = 0.75 + 0.25 * math.sin(t * 5)
        samples.append(value * swell)
    return rate, samples


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    folder = os.path.join(root, "samples", "mygame", "content", "audio")
    for name, make in (("hum", hum), ("thud", thud), ("ambience", ambience)):
        rate, samples = make()
        write_wav(os.path.join(folder, name + ".wav"), rate, samples)


main()
