#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Print the symbols both Apple's .tbd for a library exports and Finch's objects define:
the exported-symbols list for that library.

    tbd-exports.py LIBRARY.tbd OBJECT...
"""
import re
import subprocess
import sys

tbd = open(sys.argv[1]).read()
apple = set(re.findall(r"'?(_[A-Za-z0-9_$.]+)'?", tbd.split("exports:", 1)[-1]))
defined = set()
for line in subprocess.run(["nm", "-gUj", *sys.argv[2:]], capture_output=True, text=True,
                           check=True).stdout.splitlines():
    if line.startswith("_"):
        defined.add(line.strip())
for symbol in sorted(apple & defined):
    print(symbol)
