#!/usr/bin/env python3
"""Generate original, short DTMF UI effects; no third-party audio assets."""
import math
from pathlib import Path
import struct
import wave

output = Path(__file__).resolve().parents[1] / "ios/DJOneHubUACProbe/AirPhone/DialpadSounds"
output.mkdir(exist_ok=True)
rate = 22050
count = round(rate * 0.09)
fade = round(rate * 0.006)
rows = [(697, ["1", "2", "3"]), (770, ["4", "5", "6"]),
        (852, ["7", "8", "9"]), (941, ["star", "0", "hash"])]
for low, keys in rows:
    for high, key in zip([1209, 1336, 1477], keys):
        samples = []
        for i in range(count):
            envelope = min(1, i / fade, (count - 1 - i) / fade)
            tone = math.sin(2 * math.pi * low * i / rate) + math.sin(2 * math.pi * high * i / rate)
            samples.append(round(0.18 * 32767 * envelope * tone))
        with wave.open(str(output / f"{key}.wav"), "wb") as audio:
            audio.setnchannels(1)
            audio.setsampwidth(2)
            audio.setframerate(rate)
            audio.writeframes(struct.pack(f"<{count}h", *samples))
