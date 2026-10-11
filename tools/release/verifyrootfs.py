#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Verify a Finch userland payload without extracting or running any of it.

Hashes prove that the manifest matches the payload. This is not signature or
publisher verification; unsigned payloads must not be trusted as updates.
"""
import argparse
import hashlib
import json
from pathlib import Path
import tarfile

from mkrootfs import MANIFEST, check_links, record, safe_path


REQUIRED = {'sbin/launchd', 'usr/lib/dyld', 'usr/lib/libSystem.B.dylib', 'bin/sh',
            'usr/bin/login', 'private/etc/master.passwd', 'private/etc/passwd',
            'private/etc/group', 'private/etc/pam.d/login', 'private/etc/finch/rc'}


def verify(path, require_system=True):
    observed = {}
    pam_modules = set()
    manifest = None
    with tarfile.open(path, 'r|gz') as tar:
        for item in tar:
            name = safe_path(item.name)
            if name != item.name or name in observed:
                raise ValueError(f'absolute or repeated member: {item.name}')
            if item.isdir():
                kind = 'directory'
            elif item.issym():
                kind = 'symlink'
            elif item.isreg():
                kind = 'file'
            else:
                raise ValueError(f'unsupported archive member type: {name}')
            row = {'path': name, 'type': kind, 'mode': item.mode, 'uid': item.uid, 'gid': item.gid}
            if item.issym():
                row['target'] = item.linkname
            elif item.isreg():
                stream = tar.extractfile(item)
                digest = hashlib.sha256()
                size = 0
                manifest_parts = []
                pam_parts = []
                passwd_parts = []
                while True:
                    chunk = stream.read(1024 * 1024)
                    if not chunk:
                        break
                    size += len(chunk)
                    digest.update(chunk)
                    if name.startswith('private/etc/pam.d/'):
                        if size > 64 * 1024:
                            raise ValueError('PAM settings are too large')
                        pam_parts.append(chunk)
                    if name == 'private/etc/passwd':
                        if size > 8 * 1024 * 1024:
                            raise ValueError('public account file is too large')
                        passwd_parts.append(chunk)
                    if name == MANIFEST:
                        if size > 16 * 1024 * 1024:
                            raise ValueError('manifest is too large')
                        manifest_parts.append(chunk)
                if size != item.size:
                    raise ValueError(f'truncated member: {name}')
                row.update(size=size, sha256=digest.hexdigest())
                if name == MANIFEST:
                    manifest = json.loads(b''.join(manifest_parts))
                if pam_parts:
                    pam_modules.update(read_pam_modules(b''.join(pam_parts).decode()))
                if name == 'private/etc/passwd':
                    for line in b''.join(passwd_parts).decode().splitlines():
                        if not line or line.startswith('#'):
                            continue
                        fields = line.split(':')
                        if len(fields) != 7 or fields[1] != '*':
                            raise ValueError('public account file contains an unsafe password field')
            wanted = record(name, kind, item.mode)
            if any(row[key] != wanted[key] for key in ('uid', 'gid', 'mode')):
                raise ValueError(f'unsafe owner or mode: {name}')
            if kind != 'symlink' and item.mode & 0o022 and name not in ('private/tmp', 'private/var/tmp'):
                raise ValueError(f'group/world-writable system path: {name}')
            observed[name] = row
    if not isinstance(manifest, dict) or manifest.get('format') != 1 or manifest.get('kind') != 'finch-userland-payload':
        raise ValueError('missing or unknown manifest')
    expected = {}
    for row in manifest.get('files', []):
        name = safe_path(row['path'])
        if name in expected or name == MANIFEST:
            raise ValueError(f'repeated or self-listed manifest path: {name}')
        expected[name] = row
    observed.pop(MANIFEST, None)
    if observed.keys() != expected.keys():
        raise ValueError('manifest and archive have different paths')
    for name, row in observed.items():
        if row != expected[name]:
            raise ValueError(f'manifest does not match: {name}')
        for parent in Path(name).parents:
            if str(parent) != '.' and observed.get(str(parent), {}).get('type') != 'directory':
                raise ValueError(f'archive member has an unsafe parent: {name}')
    check_links(observed)
    for module in pam_modules:
        if not any(observed.get(candidate, {}).get('type') == 'file' for candidate in (module, module + '.2')):
            raise ValueError(f'missing PAM module: {module}')
    if require_system and not REQUIRED <= observed.keys():
        raise ValueError(f'missing system files: {sorted(REQUIRED - observed.keys())}')
    return manifest


def read_pam_modules(contents):
    modules = set()
    for line in contents.splitlines():
        line = line.split('#', 1)[0].strip()
        if not line:
            continue
        fields = line.split()
        if len(fields) < 3 or fields[0] not in {'auth', 'account', 'password', 'session'}:
            raise ValueError('unsupported PAM settings')
        if fields[1] not in {'required', 'requisite', 'sufficient', 'optional'}:
            raise ValueError('unsupported PAM control')
        module = fields[2]
        if '/' not in module:
            module = 'usr/lib/pam/' + module
        elif module.startswith('/usr/lib/pam/'):
            module = module[1:]
        else:
            raise ValueError('PAM module outside the system module directory')
        modules.add(safe_path(module))
    return modules


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archive', type=Path)
    args = parser.parse_args()
    manifest = verify(args.archive)
    print(f"verified {len(manifest['files'])} paths, owners, modes, links and file hashes")
    print('unsigned payload: this check does not establish who made it')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, KeyError, tarfile.TarError) as error:
        raise SystemExit(str(error))
