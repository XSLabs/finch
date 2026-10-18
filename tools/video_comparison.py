#!/usr/bin/env python3
"""Compare video test output while allowing the existing lossy-codec tolerance."""
import re
import sys
from pathlib import Path

MEANS = re.compile(r'^decoded RGB means r=([0-9]+(?:\.[0-9]+)?) g=([0-9]+(?:\.[0-9]+)?) b=([0-9]+(?:\.[0-9]+)?)$')


def matches(expected, actual):
    left, right = expected.splitlines(), actual.splitlines()
    if not left or len(left) != len(right):
        return False
    for a, b in zip(left, right):
        am, bm = MEANS.fullmatch(a), MEANS.fullmatch(b)
        if am and bm:
            av, bv = list(map(float, am.groups())), list(map(float, bm.groups()))
            if any(not 0 <= value <= 255 for value in av + bv):
                return False
            if any(abs(x - y) > 16 for x, y in zip(av, bv)):
                return False
        elif a != b:
            return False
    return True


if __name__ == '__main__':
    raise SystemExit(0 if matches(Path(sys.argv[1]).read_text(),
                                 Path(sys.argv[2]).read_text()) else 1)
