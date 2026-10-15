#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Launch apps from this Mac's install in the VM, one after another in one boot, and say which
come up: still running after a while, with a titled window. Apple's apps come from the
user's install at image build time, never the repository.

  FINCH_HOST_APPS="Calculator,TextEdit" tools/vm/mkramdisk.sh
  tools/vm/app-launch.py Calculator TextEdit          (names as FINCH_HOST_APPS takes them)
  tools/vm/app-launch.py --ready                      (docs/APPS.md's "Ready" apps)
  tools/vm/app-launch.py --seconds 40 ...             (time each app runs; 25 by default)

Prints one line per app: "up" with its windows' titles, "no window", "crashed" (with the
runner's status) or "not in the image". Exits non-zero if any app isn't up.
"""
import plistlib
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PLACES = ['/System/Applications', '/System/Applications/Utilities', '/Applications']
BOOT_FAILED = '### VM exited before the shell started'


def executable(name):
    for place in PLACES:
        info = Path(place) / f'{name}.app' / 'Contents' / 'Info.plist'
        if info.exists():
            return plistlib.loads(info.read_bytes()).get('CFBundleExecutable')
    return None


def ready_apps():
    text = (ROOT / 'docs/APPS.md').read_text()
    m = re.search(r'^Ready: (.*)\.$', text, re.M)
    return [a.strip() for a in m.group(1).split(',')] if m else []


def main():
    argv = sys.argv[1:]
    seconds = 25
    if '--seconds' in argv:
        i = argv.index('--seconds')
        seconds = int(argv[i + 1])
        del argv[i:i + 2]
    apps = ready_apps() if '--ready' in argv else [a for a in argv if not a.startswith('--')]
    if not apps:
        sys.exit(__doc__)
    commands = []
    for i, name in enumerate(apps):
        exe = executable(name)
        path = f'/Applications/{name}.app/Contents/MacOS/{exe}'
        out = f'/tmp/app-launch-{i}.out'
        # (the markers are split in the command, so the console's echo of it, wrapped at its
        # width, never looks like a result)
        commands.append(
            f"if [ -x '{path}' ]; then finch-app-test /usr/libexec/finch-windowserver '{path}' "
            f"wait:{seconds * 1000} windows > {out} 2>&1; s=$?; else s=missing; fi; "
            f"echo \"A\"\"PP|{i}|$s\"; grep -E '^  window ' {out} 2>/dev/null "
            f"| sed \"s/^/W\"\"IN|{i}|/\"; grep -E '^(crash:|app failed)' {out} 2>/dev/null | head -3 | sed \"s/^/E\"\"RR|{i}|/\"; true")
    log = tempfile.NamedTemporaryFile(prefix='app-launch.', suffix='.log', delete=False)
    print(f'VM log: {log.name}', flush=True)
    for attempt in range(2):
        log.seek(0)
        log.truncate()
        subprocess.run([str(ROOT / 'tools/vm/with-vm-lock.sh'), 'expect', str(ROOT / 'tools/vm/smoke.exp')] + commands,
                       cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
        log.flush()
        text = re.sub(r'\x1b\[[0-9;?]*[A-Za-z]', '', Path(log.name).read_text(errors='replace'))
        if BOOT_FAILED not in text:
            break
        print('the VM stopped before its shell started; booting it again', flush=True)
    failed = 0
    for i, name in enumerate(apps):
        m = re.search(rf'^APP\|{i}\|(\S+)\s*$', text, re.M)
        listed = re.findall(rf'^WIN\|{i}\|  window "([^"]*)" (\S+) level (-?\d+)\s*$', text, re.M)
        windows = [t for t, size, level in listed if t and level == '0']
        others = ', '.join(f'"{t}" {size} level {level}' for t, size, level in listed if not (t and level == '0') and level != '24')
        errors = re.findall(rf'^ERR\|{i}\|(.*?)\s*$', text, re.M)
        if not m:
            verdict = 'no result (see the VM log)'
        elif m.group(1) == 'missing':
            verdict = 'not in the image'
        elif m.group(1) != '0' or errors:
            verdict = f'crashed (runner status {m.group(1)}){": " + errors[0] if errors else ""}'
        elif not windows:
            verdict = 'no window' + (f' (others: {others})' if others else '')
        else:
            print(f'{name:28} up: {", ".join(windows)}')
            continue
        failed += 1
        print(f'{name:28} {verdict}')
    print(f'{len(apps) - failed} of {len(apps)} up')
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
