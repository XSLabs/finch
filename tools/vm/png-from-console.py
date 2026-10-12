#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Decode a screenshot finch-app-test printed over the VM console (screenshot64).

The image comes as numbered lines (P<n>:<checksum>:<base64>), twice, after a BEGIN-PNG
line. Kernel messages can land inside a line, so each line's first copy whose checksum
holds is kept. A log with several screenshots gives OUT-1.png, OUT-2.png, ...
    tools/vm/png-from-console.py LOG OUT.png
"""
import base64
import re
import sys


def checksum(s):
    v = 0
    for ch in s.encode():
        v = (v * 31 + ch) & 0xFFFF
    return v


def decode(text):
    lines = {}
    for m in re.finditer(r"P(\d+):([0-9a-f]{4}):([A-Za-z0-9+/=]+)", text):
        n, s, data = int(m.group(1)), int(m.group(2), 16), m.group(3)
        if n not in lines and checksum(data) == s:
            lines[n] = data
    if not lines:
        return None, "no image"
    count = max(lines) + 1
    missing = [n for n in range(count) if n not in lines]
    if missing:
        return None, f"{len(missing)} of {count} lines lost (first {missing[0]})"
    return base64.b64decode("".join(lines[n] for n in range(count))), None


def main():
    log, out = sys.argv[1], sys.argv[2]
    text = open(log, "rb").read().decode("latin-1").replace("\r", "")
    parts = text.split("BEGIN-PNG")[1:] or [text]
    if len(parts) == 1:
        png, err = decode(parts[0])
        if err:
            sys.exit(err)
        open(out, "wb").write(png)
        return
    stem, dot, ext = out.rpartition(".")
    for k, part in enumerate(parts, 1):
        name = f"{stem}-{k}.{ext}" if dot else f"{out}-{k}"
        png, err = decode(part)
        if err:
            print(f"{name}: {err}")
            continue
        open(name, "wb").write(png)
        print(name)


main()
