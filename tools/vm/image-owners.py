#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Write the owner manifest of a development system image.

    tools/vm/image-owners.py MOUNTED-IMAGE

The image is built on the host without root (tools/vm/mkramdisk.sh), so its
files can't be given to root there and setuid bits don't stick. This lists the
owner and mode every file should have, by the release archive's rules
(tools/release/mkrootfs.py: root:wheel, its private, volatile and setuid
paths), as MODE UID GID PATH lines in usr/share/finch/image-owners.txt inside
the image. finch-volume-setup applies it as root in the guest
(tools/vm/mkpersistent.sh).
"""
import os
import stat
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'release'))
from mkrootfs import record  # noqa: E402

MANIFEST = 'usr/share/finch/image-owners.txt'
# The account templates the data volume is seeded from: the private one stays private.
EXTRA_PRIVATE = {'usr/share/finch/accounts/master.passwd'}


def entries(root):
    yield '.', 0o755, 0, 0
    for directory, dirs, files in os.walk(root, followlinks=False):
        for name in sorted(dirs + files):
            full = Path(directory) / name
            path = full.relative_to(root).as_posix()
            st = full.lstat()
            if stat.S_ISLNK(st.st_mode):
                kind = 'symlink'
            elif stat.S_ISDIR(st.st_mode):
                kind = 'directory'
            elif stat.S_ISREG(st.st_mode):
                kind = 'file'
            else:
                raise SystemExit(f'unexpected file type in the image: {path}')
            entry = record(path, kind, st.st_mode)
            mode = 0o600 if path in EXTRA_PRIVATE else entry['mode']
            yield path, mode, entry['uid'], entry['gid']


def main():
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    root = Path(sys.argv[1])
    (root / MANIFEST).unlink(missing_ok=True)
    lines = [f'{mode:o} {uid} {gid} {path}' for path, mode, uid, gid in entries(root)]
    if any('\n' in line for line in lines):
        raise SystemExit('a path in the image contains a newline')
    # The manifest lists itself.
    lines.append(f'644 0 0 {MANIFEST}')
    (root / MANIFEST).write_text('\n'.join(lines) + '\n')
    print(f'image-owners: {len(lines)} entries')


if __name__ == '__main__':
    main()
