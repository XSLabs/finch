#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Finch's SBPL compiler against macOS's, on every profile this Mac has.

    tests/compare.py                 compile acceptance and decisions
    tests/compare.py --compile-only  compile acceptance only

Acceptance: each profile in /System/Library/Sandbox/Profiles and
/usr/share/sandbox is compiled by both (macOS's through sandbox-exec, Finch's
through sbplc) with the same parameters; the two must agree on whether it
compiles, except where macOS's own behavior is inconsistent (KNOWN_ACCEPTANCE).

Decisions: for each profile both accept, decision-diff applies it with macOS's
sandbox in a child and asks Finch's evaluator the same questions. Finch may
deny more than macOS (an approximation, reported); it must never allow what
macOS denies, except for the platform rule KNOWN_PLATFORM names.

Run on the build Mac; needs sandbox-exec and build/obj/libsandbox's tools
(make sbplc, and decision-diff for the full run).
"""
import glob
import os
import re
import subprocess
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
OBJ = ROOT / 'build/obj/libsandbox'
FOLDERS = ['/System/Library/Sandbox/Profiles', '/usr/share/sandbox']

# Profiles macOS refuses where it accepts the same construct elsewhere
# ((allow ipc-posix-shm) and (with no-log)); Finch accepts both.
KNOWN_ACCEPTANCE = {'fontmoverinternal.sb', 'fontworkerinternal.sb'}
# macOS's platform policy denies raw disks to every sandboxed process, beyond
# what profiles say; Finch's raw disks keep their owners' permissions.
KNOWN_PLATFORM = re.compile(r'^file-read-data /dev/disk\d+: macOS denies, Finch allows$')
# Paths macOS's sandbox names differently from realpath(): files reached
# through the mounted time-zone data (/var/db/timezone/tz/...), and
# /private/var/folders on the Data volume. Finch's kernel uses the resolved
# path the test uses.
KNOWN_PATHS = {
    ('com.apple.doubleagentd.sb', 'file-read-data /private/var/db/timezone/zoneinfo/UTC'),
    ('com.apple.doubleagentd.sb', 'file-read-data /usr/share/zoneinfo'),
    ('com.apple.ClassroomKit.ResourcesService.sb', 'file-read-metadata /private/var/folders'),
}


def profiles():
    return sorted(p for f in FOLDERS for p in glob.glob(f + '/*.sb'))


def params():
    """Every (param "X") the profiles read, with values shaped like real ones."""
    names = set()
    for p in profiles():
        names |= set(re.findall(r'\(param "([^"]+)"\)', Path(p).read_text(errors='replace')))
    home = os.environ['HOME']
    tmp = subprocess.run(['getconf', 'DARWIN_USER_TEMP_DIR'], capture_output=True, text=True).stdout.strip()
    cache = subprocess.run(['getconf', 'DARWIN_USER_CACHE_DIR'], capture_output=True, text=True).stdout.strip()
    base = '/private/var/folders/zz/zyxvpxvq6csfxvn_n0000000000000'
    fixed = {'HOME': home, '_HOME': home, '__HOME': home, 'HOME_DIR': home, 'TMPDIR': tmp,
             'DARWIN_CACHE_DIR': cache, 'UID': str(os.getuid()), '_USER': os.environ.get('USER', 'finch'),
             'CURRENT_USER': os.environ.get('USER', 'finch'), 'application_bundle_id': 'org.finch.test'}
    out = []
    for n in sorted(names):
        u = n.upper()
        v = fixed.get(n) or (base + '/C/' + n if 'CACHE' in u else base + '/T/' + n if 'TMP' in u or 'TEMP' in u
                             else base + '/0/' + n if 'DARWIN' in u or 'USER_DIR' in u
                             else '/opt/a:/opt/b' if 'PATHS' in u or 'FRAMEWORK_PATH' in u
                             else '/private/var/tmp/sbpl/' + n)
        out += ['-D', f'{n}={v}']
    return out


def macos_compiles(profile, args):
    r = subprocess.run(['sandbox-exec', '-f', profile, *args, '/usr/bin/true'], cwd='/tmp',
                       capture_output=True, text=True)
    first = (r.stderr.splitlines() or [''])[0]
    return not first or 'execvp' in first or 'sandbox_apply' in first, first


def finch_compiles(profile, args):
    includes = [x for f in FOLDERS for x in ('-I', f)]
    r = subprocess.run([str(OBJ / 'sbplc'), *includes, *args, profile], capture_output=True, text=True)
    return r.stdout.startswith('ok'), r.stdout.strip()


def main():
    compile_only = '--compile-only' in sys.argv
    args = params()
    both_ok, failures, accepted = 0, [], []
    for p in profiles():
        a, amsg = macos_compiles(p, args)
        f, fmsg = finch_compiles(p, args)
        if a and f:
            both_ok += 1
            accepted.append(p)
        elif a != f and os.path.basename(p) not in KNOWN_ACCEPTANCE:
            failures.append(f'{p}: macOS {"compiles" if a else "refuses"} ({amsg}); Finch: {fmsg}')
    print(f'acceptance: {len(profiles())} profiles, {both_ok} compile with both, '
          f'{len(failures)} disagreements')
    for line in failures:
        print('  ' + line)
    if compile_only:
        return 1 if failures else 0

    includes = [x for f in FOLDERS for x in ('-I', f)]
    decisions = differ = 0
    wider, narrower = [], Counter()
    for p in accepted:
        r = subprocess.run([str(OBJ / 'decision-diff'), *args, *includes, p], capture_output=True, text=True)
        for line in r.stdout.splitlines():
            m = re.search(r': (\d+) decisions compared, (\d+) differ', line)
            if m:
                decisions += int(m.group(1))
                differ += int(m.group(2))
            elif line.startswith('  '):
                d = line.strip()
                known = (os.path.basename(p), d.split(':')[0]) in KNOWN_PATHS
                if 'Finch allows' in d and not KNOWN_PLATFORM.match(d) and not known:
                    wider.append(f'{p}: {d}')
                elif 'Finch denies' in d:
                    narrower[d.split(':')[0]] += 1
    print(f'decisions: {decisions} compared, {differ} differ')
    print(f'  Finch denies where macOS allows: {sum(narrower.values())} '
          f'(approximated filters; most common below)')
    for what, n in narrower.most_common(10):
        print(f'    {n:4} {what}')
    print(f'  Finch allows where macOS denies: {len(wider)}')
    for line in wider:
        print('    ' + line)
    return 1 if failures or wider else 0


if __name__ == '__main__':
    sys.exit(main())
