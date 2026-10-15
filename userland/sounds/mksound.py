#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Finch's alert sound, made here (nothing of Apple's): a short chime, a sine at 880 Hz with a
fifth above it, fading out over 0.18 seconds, as 16-bit mono AIFF at 44.1 kHz.

    userland/sounds/mksound.py OUT.aiff
"""
import math
import struct
import sys

RATE, SECONDS = 44100, 0.18


def extended(value):
    """An 80-bit IEEE extended float, as AIFF stores its sample rate."""
    exponent = int(math.floor(math.log2(value)))
    mantissa = int(value / 2 ** exponent * 2 ** 63)
    return struct.pack('>HQ', 16383 + exponent, mantissa)


def main():
    frames = int(RATE * SECONDS)
    samples = bytearray()
    for i in range(frames):
        t = i / RATE
        envelope = math.exp(-t * 22) * min(1, i / 64)
        v = 0.55 * math.sin(2 * math.pi * 880 * t) + 0.25 * math.sin(2 * math.pi * 1320 * t)
        samples += struct.pack('>h', int(max(-1, min(1, v * envelope)) * 32000))
    comm = struct.pack('>hIh', 1, frames, 16) + extended(RATE)
    ssnd = struct.pack('>II', 0, 0) + bytes(samples)
    body = b'AIFF' + b'COMM' + struct.pack('>I', len(comm)) + comm + b'SSND' + struct.pack('>I', len(ssnd)) + ssnd
    with open(sys.argv[1], 'wb') as f:
        f.write(b'FORM' + struct.pack('>I', len(body)) + body)


if __name__ == '__main__':
    main()
