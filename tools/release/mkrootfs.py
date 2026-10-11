#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Pack Finch's built userland with install-time owners, modes and file hashes.

This creates an install payload, not a bootable image or a signed release.
It never changes host ownership, mounts disks, or installs files on the host.
"""
import argparse
import gzip
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import stat
import subprocess
import tarfile
import tempfile

REPO = Path(__file__).resolve().parents[2]
SETUID = {'usr/bin/at', 'usr/bin/atq', 'usr/bin/atrm', 'usr/bin/crontab', 'usr/bin/su', 'usr/bin/login'}
PRIVATE = {'private/etc/master.passwd', 'private/var/root', 'usr/lib/cron/tabs', 'usr/lib/cron/tmp'}
VOLATILE = {'private/tmp', 'private/var/tmp'}
ROOTS = {'System', 'Library', 'usr', 'bin', 'sbin', 'private'}
MANIFEST = 'usr/share/finch/release-manifest.json'


def safe_path(value):
    value = value.lstrip('/')
    path = PurePosixPath(value)
    if not value or str(path) != value or '..' in path.parts or '\x00' in value:
        raise ValueError(f'unsafe archive path: {value!r}')
    return value


def runtime_path(path):
    parts = PurePosixPath(path).parts
    return (parts[0] in ROOTS and not any(p in {'Headers', 'PrivateHeaders', 'Modules', 'include', 'AppleInternal'} or p.endswith('.dSYM') for p in parts)
            and not path.startswith('private/etc/pam.d/')
            and 'Dyld.framework' not in parts
            and not path.endswith(('.a', '.tbd', '.h')))


def record(path, kind, mode, **fields):
    uid = gid = 1 if path in {'usr/lib/cron/jobs', 'usr/lib/cron/spool'} else 0
    mode &= 0o777
    if path in PRIVATE:
        mode = 0o700 if kind == 'directory' else 0o600
    elif path in VOLATILE:
        mode = 0o1777
    elif path in SETUID and kind == 'file':
        mode = 0o4555
    return {'path': path, 'type': kind, 'mode': mode, 'uid': uid, 'gid': gid, **fields}


def collect(stage, overlay, repo=REPO):
    entries = {}

    def add(path, source):
        path = safe_path(path)
        st = source.lstat()
        if stat.S_ISLNK(st.st_mode):
            target = os.readlink(source)
            if '\x00' in target or not target:
                raise ValueError(f'invalid link: {path}')
            entries[path] = record(path, 'symlink', 0o777, target=target)
        elif stat.S_ISDIR(st.st_mode):
            entries[path] = record(path, 'directory', st.st_mode)
        elif stat.S_ISREG(st.st_mode):
            entries[path] = record(path, 'file', st.st_mode, source=source)
        else:
            raise ValueError(f'unexpected file type in build tree: {path}')

    for directory, dirs, files in os.walk(stage, followlinks=False):
        for name in sorted(dirs + files):
            source = Path(directory) / name
            path = source.relative_to(stage).as_posix()
            if runtime_path(path):
                add(path, source)
        dirs[:] = [name for name in dirs if runtime_path((Path(directory) / name).relative_to(stage).as_posix())]
    for line in overlay.read_text().splitlines():
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        source, destination = line.split()
        add(destination, repo / source)

    # Libsystem also stages links for its unbuilt address-sanitizer variant.
    # Keep real runtime links strict; omit only these known build-only links.
    if 'usr/lib/libSystem.B_asan.dylib' not in entries:
        for path in ('System/Library/Frameworks/System.framework/System_asan',
                     'System/Library/Frameworks/System.framework/Versions/B/System_asan'):
            entries.pop(path, None)

    for path in ('dev', 'Users', 'Volumes', 'Library/LaunchDaemons', 'Library/LaunchAgents',
                 'Library/Preferences', 'Library/Preferences/SystemConfiguration', 'private/tmp', 'private/var/tmp',
                 'private/var/run', 'private/var/log', 'private/var/root', 'private/var/empty', 'private/var/db',
                 'private/var/db/timezone', 'usr/lib/cron', 'usr/lib/cron/tabs', 'usr/lib/cron/tmp',
                 'usr/lib/cron/jobs', 'usr/lib/cron/spool'):
        entries[path] = record(path, 'directory', 0o755)
    for path, target in {'etc': 'private/etc', 'var': 'private/var', 'tmp': 'private/tmp',
                         'private/etc/localtime': '/usr/share/zoneinfo/UTC',
                         'private/var/db/timezone/zoneinfo': '/usr/share/zoneinfo'}.items():
        entries[path] = record(path, 'symlink', 0o777, target=target)
    master = entries['private/etc/master.passwd']['source'].read_text()
    passwd = []
    for line in master.splitlines():
        if not line or line.startswith('#'):
            continue
        fields = line.split(':')
        if len(fields) != 10:
            raise ValueError('invalid master.passwd template')
        # Password hashes stay only in the private master file.
        passwd.append(':'.join([fields[0], '*', fields[2], fields[3]] + fields[7:]))
    entries['private/etc/passwd'] = record('private/etc/passwd', 'file', 0o644, data=('\n'.join(passwd) + '\n').encode())
    for path in list(entries):
        for parent in PurePosixPath(path).parents:
            if str(parent) != '.':
                name = str(parent)
                entries.setdefault(name, record(name, 'directory', 0o755))
    for path in entries:
        for parent in PurePosixPath(path).parents:
            if str(parent) != '.' and entries[str(parent)]['type'] != 'directory':
                raise ValueError(f'archive writes through a non-directory: {path}')
    return entries


def link_target(path, target):
    parts = [] if target.startswith('/') else list(PurePosixPath(path).parent.parts)
    for part in target.split('/'):
        if part in ('', '.'):
            continue
        if part == '..':
            if not parts:
                raise ValueError(f'link escapes installed root: {path} -> {target}')
            parts.pop()
        else:
            parts.append(part)
    return '/'.join(parts)


def check_links(entries, paths=None):
    for path in entries if paths is None else paths:
        entry = entries[path]
        if entry['type'] != 'symlink':
            continue
        target = link_target(path, entry['target'])
        seen = {path}
        while True:
            parts = PurePosixPath(target).parts
            replaced = False
            for i in range(1, len(parts) + 1):
                prefix = '/'.join(parts[:i])
                item = entries.get(prefix)
                if item and item['type'] == 'symlink':
                    if prefix in seen:
                        raise ValueError(f'link cycle: {path}')
                    seen.add(prefix)
                    base = link_target(prefix, item['target'])
                    target = '/'.join([base] + list(parts[i:]))
                    replaced = True
                    break
            if not replaced:
                break
        if target not in entries:
            raise ValueError(f'missing link target: {path} -> {target}')


def archive(entries, output, epoch, metadata):
    manifest = {'format': 1, 'kind': 'finch-userland-payload', 'bootable': False,
                'signed': False, 'epoch': epoch, **metadata, 'files': []}
    for path, item in sorted(entries.items()):
        row = {k: v for k, v in item.items() if k not in {'source', 'data'}}
        if item['type'] == 'file':
            data = item.get('data')
            if data is None:
                data = item['source'].read_bytes()
            row.update(size=len(data), sha256=hashlib.sha256(data).hexdigest())
        manifest['files'].append(row)
    manifest_data = (json.dumps(manifest, sort_keys=True, indent=2) + '\n').encode()
    all_entries = dict(entries)
    all_entries[MANIFEST] = record(MANIFEST, 'file', 0o644, data=manifest_data)
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=output.parent, prefix='.rootfs-', delete=False) as raw:
            temporary = Path(raw.name)
            with gzip.GzipFile(filename='', mode='wb', fileobj=raw, mtime=epoch) as zipped:
                with tarfile.open(fileobj=zipped, mode='w|', format=tarfile.PAX_FORMAT) as tar:
                    expected = {item['path']: item for item in manifest['files']}
                    for path, item in sorted(all_entries.items()):
                        info = tarfile.TarInfo(path)
                        info.uid, info.gid, info.mode = item['uid'], item['gid'], item['mode']
                        info.uname, info.gname, info.mtime = '', '', epoch
                        if item['type'] == 'directory':
                            info.type = tarfile.DIRTYPE
                            tar.addfile(info)
                        elif item['type'] == 'symlink':
                            info.type, info.linkname = tarfile.SYMTYPE, item['target']
                            tar.addfile(info)
                        else:
                            data = item.get('data')
                            if data is None:
                                data = item['source'].read_bytes()
                            if path in expected and hashlib.sha256(data).hexdigest() != expected[path]['sha256']:
                                raise ValueError(f'file changed while packing: {path}')
                            info.size = len(data)
                            tar.addfile(info, io.BytesIO(data))
            raw.flush()
            os.fsync(raw.fileno())
        os.replace(temporary, output)
        temporary = None
        return manifest_data
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=REPO / 'build/release/rootfs.tar.gz')
    parser.add_argument('--compat-version', required=True)
    parser.add_argument('--compat-build', required=True)
    parser.add_argument('--epoch', type=int, default=int(os.environ.get('SOURCE_DATE_EPOCH', '0')))
    args = parser.parse_args()
    if args.epoch < 0:
        parser.error('epoch must be nonnegative')
    entries = collect(REPO / 'build/root', REPO / 'tools/release/overlay.txt')
    version_path = 'System/Library/CoreServices/SystemVersion.plist'
    entries[version_path] = record(version_path, 'file', 0o644, data=plistlib.dumps({
        'ProductName': 'Finch', 'ProductVersion': args.compat_version,
        'ProductBuildVersion': args.compat_build, 'FinchVersion': 'development'}))
    for path in (version_path, MANIFEST):
        for parent in PurePosixPath(path).parents:
            if str(parent) != '.':
                entries.setdefault(str(parent), record(str(parent), 'directory', 0o755))
    check_links(entries)
    head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=REPO, text=True).strip()
    dirty = bool(subprocess.check_output(['git', 'status', '--porcelain'], cwd=REPO, text=True).strip())
    manifest = archive(entries, args.output, args.epoch, {'source_commit': head, 'source_dirty': dirty,
        'source_projects': (REPO / 'userland/projects.txt').read_text(),
        'compat_version': args.compat_version, 'compat_build': args.compat_build})
    args.output.with_suffix('.manifest.json').write_bytes(manifest)
    print(f'packed {len(entries)} paths into {args.output}')
    print('unsigned userland payload; hardware boot, account setup and installer remain required')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError) as error:
        raise SystemExit(str(error))
