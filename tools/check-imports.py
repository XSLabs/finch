#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Which of a binary's imports Finch's images don't export yet.

    tools/check-imports.py path/to/binary [--root build/root] [--all]

For each library the binary links (dyld_info -imports), finds Finch's image
of that install name under the root, collects its exports and those of the
libraries it re-exports (recursively), and lists the imported symbols that
none of them export. Weak imports are marked; they don't stop a launch.
Libraries Finch has no image for are listed separately.
"""
import argparse
import collections
import os
import re
import subprocess
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "build", "root")


def run(*args):
    out = subprocess.run(args, capture_output=True, text=True).stdout
    # Binaries built for the current arm64e ABI report their slice as "arm64e.v1", which
    # "-arch arm64e" doesn't select; a single-slice binary is read without the filter.
    if args[1:3] == ("-arch", "arm64e") and len(out.splitlines()) <= 1:
        out = subprocess.run(args[:1] + args[3:], capture_output=True, text=True).stdout
    return out


_overlay = None


def overlay():
    """Install paths of images built outside the root (tools/vm/overlay.txt: source, destination)."""
    global _overlay
    if _overlay is None:
        top = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
        _overlay = {}
        with open(os.path.join(top, "tools", "vm", "overlay.txt")) as f:
            for line in f:
                parts = line.split()
                if len(parts) == 2 and not line.startswith("#"):
                    _overlay[parts[1]] = os.path.join(top, parts[0])
    return _overlay


def image_path(root, install_name):
    p = os.path.join(root, install_name.lstrip("/"))
    if os.path.exists(p):
        return p
    p = overlay().get(install_name)
    return p if p and os.path.exists(p) else None


_exports = {}


def exports_of(root, install_name, seen=None):
    """Symbols an install name provides, following re-exports."""
    if install_name in _exports:
        return _exports[install_name]
    seen = seen or set()
    if install_name in seen:
        return set()
    seen.add(install_name)
    path = image_path(root, install_name)
    syms = set()
    if path:
        for line in run("dyld_info", "-arch", "arm64e", "-exports", path).splitlines():
            m = re.match(r"\s+(?:0x[0-9A-Fa-f]+|\[re-export\])\s+(\S+)", line)
            if m:
                syms.add(m.group(1))
        for line in run("dyld_info", "-arch", "arm64e", "-linked_dylibs", path).splitlines():
            m = re.match(r"\s+re-export\s+(\S+)", line)
            if m:
                syms |= exports_of(root, m.group(1), seen)
    _exports[install_name] = syms
    return syms


def check(binary, root=ROOT):
    """What a binary imports that Finch's images don't export: (absent, missing_libs, weak),
    absent mapping each library's short name to (missing (symbol, weak) pairs, import count),
    missing_libs listing (short name, install name, import count) for libraries with no image."""
    libs = {}
    weak = set()
    for line in run("dyld_info", "-arch", "arm64e", "-linked_dylibs", binary).splitlines():
        m = re.match(r"\s+((?:weak-link|upward|re-export|reexport)\s+)*([/@].*?)\s*$", line)
        if m:
            libs[os.path.basename(m.group(2))] = m.group(2)
            if m.group(1) and "weak" in m.group(1):
                weak.add(m.group(2))
    # (libraries the app carries itself, @rpath/... and the like, aren't Finch's to provide)
    bundled = {short for short, install in libs.items() if install.startswith("@")}
    imports = collections.defaultdict(list)
    for line in run("dyld_info", "-arch", "arm64e", "-imports", binary).splitlines():
        m = re.match(r"\s+0x[0-9A-Fa-f]+\s+(\S+)\s+(\[weak-import\]\s+)?\(from ([^)]+)\)", line)
        if m:
            imports[m.group(3)].append((m.group(1), bool(m.group(2))))
    missing_libs = []
    absent = {}
    for short, syms in sorted(imports.items()):
        install = next((v for k, v in libs.items() if k == short or k.startswith(short)), None)
        # (bundled libraries, and weak definitions bound wherever they're found)
        if install and install.startswith("@") or short in bundled or short.startswith("<"):
            continue
        if not install or not image_path(root, install):
            missing_libs.append((short, install, len(syms)))
            continue
        have = exports_of(root, install)
        gone = [(s, w) for s, w in syms if s not in have]
        if gone:
            absent[short] = (gone, len(syms))
    imported = {install for _, install, _ in missing_libs}
    for install in libs.values():
        if install not in imported and not install.startswith("@") and not image_path(root, install) and install not in weak:
            missing_libs.append((os.path.basename(install), install, 0))
    return absent, missing_libs, weak


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("binary")
    ap.add_argument("--root", default=ROOT)
    ap.add_argument("--all", action="store_true", help="list every missing symbol, not just counts per library")
    args = ap.parse_args()

    absent, missing_libs, weak = check(args.binary, args.root)
    total = 0
    for short, (gone, count) in absent.items():
        total += len(gone)
        print(f"{short}: {len(gone)} of {count} missing")
        if args.all:
            for s, w in gone:
                print(f"    {s}{'  [weak]' if w else ''}")
    for short, install, n in missing_libs:
        print(f"no image: {install or short} ({n} imports){'  [weak]' if install in weak else ''}")
    print(f"{total} missing symbols, {len(missing_libs)} missing libraries")
    return 1 if total or missing_libs else 0


if __name__ == "__main__":
    sys.exit(main())
