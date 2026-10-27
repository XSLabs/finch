#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Check, in a running VM, that every image its processes have loaded is Finch's.

    tools/vm/check-loaded-images.py [--seconds N] [--keep LOG]

Boots the image built by tools/vm/mkramdisk.sh, waits N seconds (30 by default)
for the boot's services to start, then runs `finch-images --all`, which lists
every image of every running process from dyld's own image list: programs,
linked libraries and those opened later with dlopen. Each image counts as
Finch's when build/root or tools/vm/overlay.txt supplies its path; anything
else comes from darwin-vm's base image, which is Apple's. This is the
measurement docs/design/PHASE1-EXIT.md asks for: tools/check-boot-path.py
follows only static links.

Prints the base-image images with the processes that loaded them, then a
summary. Exits 1 if any process loaded a base-image image or its image list
couldn't be read.
"""
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
STAGE = ROOT / 'build' / 'root'
BOOT_FAILED = '### VM exited before the shell started'
# /var, /tmp and /etc are links into /private in the image.
ALIASES = (('/var/', '/private/var/'), ('/tmp/', '/private/tmp/'), ('/etc/', '/private/etc/'))


def overlay():
    dsts = set()
    for line in (ROOT / 'tools/vm/overlay.txt').read_text().splitlines():
        line = line.strip()
        if line and not line.startswith('#'):
            dsts.add(line.split()[1])
    return dsts


def finch_supplies(path, supplied):
    candidates = {path}
    for short, full in ALIASES:
        if path.startswith(short):
            candidates.add(full + path[len(short):])
        elif path.startswith(full):
            candidates.add(short + path[len(full):])
    for p in candidates:
        if p in supplied or os.path.lexists(STAGE / p.lstrip('/')):
            return True
    return False


def main():
    argv = sys.argv[1:]
    seconds, keep = 30, None
    if '--seconds' in argv:
        i = argv.index('--seconds')
        seconds = int(argv[i + 1])
        del argv[i:i + 2]
    if '--keep' in argv:
        i = argv.index('--keep')
        keep = argv[i + 1]
        del argv[i:i + 2]
    if argv:
        sys.exit(__doc__)
    # (the marker is split in the command, so the console's echo of it never matches)
    command = f"sleep {seconds}; /usr/local/bin/finch-images --all | sed \"s/^/I\"\"MG|/\"; echo \"D\"\"ONE|$?\""
    log = open(keep, 'w+') if keep else tempfile.NamedTemporaryFile('w+', prefix='loaded-images.', suffix='.log',
                                                                    delete=False)
    print(f'VM log: {log.name}', flush=True)
    for attempt in range(2):
        log.seek(0)
        log.truncate()
        subprocess.run([str(ROOT / 'tools/vm/with-vm-lock.sh'), 'expect', str(ROOT / 'tools/vm/smoke.exp'), command],
                       cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
        log.flush()
        text = re.sub(r'\x1b\[[0-9;?]*[A-Za-z]', '', Path(log.name).read_text(errors='replace')).replace('\r', '')
        if BOOT_FAILED not in text:
            break
        print('the VM stopped before its shell started; booting it again', flush=True)
    if not re.search(r'^DONE\|0\s*$', text, re.M):
        print('finch-images --all did not finish (see the VM log)')
        return 1

    supplied = overlay()
    processes, unreadable, closed = {}, [], {}
    for pid, program, image in re.findall(r'^IMG\|(\d+)\t([^\t\n]*)\t([^\n]*?)\s*$', text, re.M):
        processes.setdefault(pid, program)
        if image == '?':
            unreadable.append(f'{pid} {program}')
        elif not finch_supplies(image, supplied):
            closed.setdefault(image, set()).add(f'{Path(program).name}[{pid}]')
    images = {i for _, _, i in re.findall(r'^IMG\|(\d+)\t([^\t\n]*)\t([^\n]*?)\s*$', text, re.M) if i != '?'}

    for image in sorted(closed):
        print(f'base image: {image}  ({", ".join(sorted(closed[image]))})')
    for p in unreadable:
        print(f'unreadable: {p}')
    print(f'{len(processes)} processes, {len(images)} distinct images: '
          f'{len(images) - len(closed)} Finch\'s, {len(closed)} from the base image, '
          f'{len(unreadable)} processes unreadable')
    return 1 if closed or unreadable or not processes else 0


if __name__ == '__main__':
    sys.exit(main())
