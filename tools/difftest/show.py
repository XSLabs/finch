#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Run one generated comparison item on both sides and show its cases decoded.

    tools/difftest/show.py FRAMEWORK "NSIndexSet -indexLessThanIndex:" [...]

Uses the program and metadata the last tools/difftest/run.py FRAMEWORK built
(build/difftest), runs each named item against Apple's framework and Finch's,
and prints every output line with its hex fields decoded, marking the cases
that differ. Item names are the difftest names ("Class -selector", "Class
+selector", or a C function's name).
"""
import importlib.util
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("difftest_run", HERE / "run.py")
run = importlib.util.module_from_spec(spec)
spec.loader.exec_module(run)


def decode(field):
    def text(match):
        try:
            return bytes.fromhex(match.group(0)).decode()
        except (ValueError, UnicodeDecodeError):
            return match.group(0)
    previous = None
    while previous != field:
        previous, field = field, re.sub(r"(?:[0-9a-f]{2}){3,}", text, field)
    return field


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    framework, names = sys.argv[1], sys.argv[2:]
    generator = run.load_generator()
    metadata = generator.generate(framework, run.BUILD / "generated")
    binary = run.build_program(framework, Path(metadata["source"]))
    details = json.loads(Path(metadata["type_metadata"]).read_text())
    image = run.finch_framework_image(framework, run.ROOT / "build/root")
    for name in names:
        info = details.get("objc", {}).get(name) or details.get("types", {}).get(name)
        meta = json.dumps(info, separators=(",", ":")) if info else "{}"
        apple = run.invoke(binary, name, meta, finch=False, timeout=30)
        finch = run.invoke(binary, name, meta, finch=True, timeout=30, expected_image=image)
        print(f"== {name}")
        a, f = apple["stdout"], finch["stdout"]
        for i in range(max(len(a), len(f))):
            la = a[i] if i < len(a) else "(none)"
            lf = f[i] if i < len(f) else "(none)"
            mark = "  " if la == lf else "≠ "
            print(f"{mark}apple: {decode(la)[:400]}")
            if la != lf:
                print(f"  finch: {decode(lf)[:400]}")
        if finch["stderr"] and not finch["source_verified"]:
            print("  (finch stderr: " + finch["stderr"][:300] + ")")


if __name__ == "__main__":
    main()
