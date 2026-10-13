#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Which apps on this Mac would launch on Finch's frameworks, and what the rest lack.

    tools/app-sweep.py [--root build/root] [--markdown] [APP_DIR ...]

Runs check-imports over the main executable of every app in /System/Applications,
/System/Applications/Utilities and /Applications (or the directories given), and over the
frameworks each app carries, then ranks
what's missing by how many apps it blocks: libraries Finch has no image of, and
libraries whose images lack symbols apps import. Weak imports don't block a launch and
aren't counted. Apps are read from the user's own install; nothing is copied.
"""
import argparse
import collections
import importlib.util
import os
import plistlib
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("check_imports", os.path.join(HERE, "check-imports.py"))
check_imports = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check_imports)

DIRS = ["/System/Applications", "/System/Applications/Utilities", "/Applications"]


def executable(app):
    try:
        with open(os.path.join(app, "Contents", "Info.plist"), "rb") as f:
            name = plistlib.load(f).get("CFBundleExecutable")
    except (OSError, plistlib.InvalidFileException):
        return None
    path = name and os.path.join(app, "Contents", "MacOS", name)
    return path if path and os.path.isfile(path) else None


def bundled(app):
    """The binaries an app carries besides its own: its frameworks (Contents/Frameworks/
    *.framework) and the plug-in bundles it loads (any bundle with an executable under
    Contents/PlugIns or Contents/Resources, as ColorSync Utility's .csutil modules; app
    extensions run in processes of their own, so they don't count). Their imports from
    the system count against Finch too."""
    found = []
    top = os.path.join(app, "Contents", "Frameworks")
    if os.path.isdir(top):
        for entry in sorted(os.listdir(top)):
            if entry.endswith(".framework"):
                binary = os.path.join(top, entry, entry[: -len(".framework")])
                if os.path.isfile(binary):
                    found.append(os.path.realpath(binary))
    for folder in ("PlugIns", "Resources"):
        top = os.path.join(app, "Contents", folder)
        if not os.path.isdir(top):
            continue
        for entry in sorted(os.listdir(top)):
            path = os.path.join(top, entry)
            if os.path.isdir(os.path.join(path, "Contents")) and not entry.endswith((".app", ".appex")):
                binary = executable(path)
                if binary:
                    found.append(os.path.realpath(binary))
    return found


def framework(install):
    """A readable name for an install name: the framework's, or the dylib's."""
    if not install:
        return "?"
    for part in install.split("/"):
        if part.endswith(".framework"):
            return part[: -len(".framework")]
    return os.path.basename(install)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dirs", nargs="*", default=DIRS)
    ap.add_argument("--root", default=check_imports.ROOT)
    ap.add_argument("--markdown", action="store_true", help="print the report as Markdown tables")
    args = ap.parse_args()

    ready, blocked = [], {}
    no_image = collections.defaultdict(set)    # framework -> apps
    short = collections.defaultdict(set)       # framework -> apps missing its symbols
    short_count = collections.Counter()        # framework -> missing symbols, summed
    for d in args.dirs:
        if not os.path.isdir(d):
            continue
        for entry in sorted(os.listdir(d)):
            if not entry.endswith(".app"):
                continue
            app = entry[:-4]
            exe = executable(os.path.join(d, entry))
            if not exe:
                continue
            libs_missing = {}
            symbols_short = collections.defaultdict(set)
            for binary in [exe] + bundled(os.path.join(d, entry)):
                absent, missing_libs, weak = check_imports.check(binary, args.root)
                for _, install, _ in missing_libs:
                    if install not in weak:
                        libs_missing[framework(install)] = True
                for lib, (gone, _) in absent.items():
                    symbols_short[framework(lib)] |= {s for s, w in gone if not w}
            needs = []
            for f in libs_missing:
                no_image[f].add(app)
                needs.append(f)
            for f, syms in symbols_short.items():
                if syms:
                    short[f].add(app)
                    short_count[f] += len(syms)
                    needs.append(f"{f} ({len(syms)} symbols)")
            if needs:
                blocked[app] = needs
            else:
                ready.append(app)

    total = len(ready) + len(blocked)
    if args.markdown:
        print(f"{len(ready)} of {total} apps have every import Finch's frameworks provide.\n")
        print("| Missing | Apps blocked | Kind |\n|---|---|---|")
        rows = [(len(a), f, "no image") for f, a in no_image.items()]
        rows += [(len(a), f, f"{short_count[f]} symbols short") for f, a in short.items()]
        for n, f, kind in sorted(rows, key=lambda r: (-r[0], r[1])):
            print(f"| {f} | {n} | {kind} |")
        print("\n| App | Lacks |\n|---|---|")
        for app in sorted(blocked):
            print(f"| {app} | {', '.join(blocked[app])} |")
        if ready:
            print(f"\nReady: {', '.join(sorted(ready))}.")
        return 0
    print(f"ready ({len(ready)} of {total}): {', '.join(sorted(ready))}")
    print("\nframeworks Finch has no image of, by apps blocked:")
    for f, a in sorted(no_image.items(), key=lambda kv: (-len(kv[1]), kv[0])):
        print(f"  {len(a):3}  {f}")
    # Apps one framework away, and apps that need nothing Finch doesn't have at all
    lone = collections.defaultdict(list)
    near = []
    for app, needs in blocked.items():
        names = {n.split(" (")[0] for n in needs}
        if len(names) == 1:
            lone[names.pop()].append(app)
        if all(" symbols)" in n for n in needs):
            near.append(app)
    print("\nblocked by one framework alone:")
    for f, a in sorted(lone.items(), key=lambda kv: (-len(kv[1]), kv[0])):
        print(f"  {len(a):3}  {f}: {', '.join(sorted(a))}")
    print(f"\nonly short of symbols in Finch's frameworks ({len(near)}): {', '.join(sorted(near))}")
    print("\nFinch frameworks short of symbols, by apps blocked:")
    for f, a in sorted(short.items(), key=lambda kv: (-len(kv[1]), kv[0])):
        print(f"  {len(a):3}  {f}  ({short_count[f]} symbols over all apps)")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (check_imports.InspectionError, OSError) as error:
        print(f"app scan failed: {error}", file=sys.stderr)
        sys.exit(2)
