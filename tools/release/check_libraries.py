#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Check strong library links using only files inside a verified Finch payload.

This checks recorded links, not symbol availability or libraries opened at runtime.
Weak links are reported separately because missing weak libraries do not stop loading.
"""
import argparse
from pathlib import Path
import struct
import tarfile

from mkrootfs import link_target
from verifyrootfs import verify


def links(data):
    if data[:4] in (b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca'):
        endian = '>' if data[:4] == b'\xca\xfe\xba\xbe' else '<'
        count, = struct.unpack_from(endian + 'I', data, 4)
        if count > 64:
            raise ValueError('invalid universal binary')
        result = []
        for i in range(count):
            _, _, offset, size, _ = struct.unpack_from(endian + 'IIIII', data, 8 + i * 20)
            if offset + size > len(data):
                raise ValueError('truncated universal binary')
            result.extend(links(data[offset:offset + size]))
        return result
    if data[:4] != b'\xcf\xfa\xed\xfe':
        return []
    count, size = struct.unpack_from('<II', data, 16)
    end = 32 + size
    if end > len(data) or count > size // 8:
        raise ValueError('invalid Mach-O header')
    offset = 32
    result = []
    for _ in range(count):
        command, length = struct.unpack_from('<II', data, offset)
        if length < 8 or offset + length > end:
            raise ValueError('invalid Mach-O command')
        if command in (0xc, 0x80000018, 0x8000001f, 0x20, 0x80000023):
            if length < 24:
                raise ValueError('invalid library command')
            start, = struct.unpack_from('<I', data, offset + 8)
            if start < 24 or start >= length:
                raise ValueError('invalid library name')
            name = data[offset + start:offset + length].split(b'\0', 1)[0].decode()
            result.append((name, command == 0x80000018))
        offset += length
    return result


def resolve(name, entries):
    name = name.lstrip('/')
    seen = set()
    while name not in seen:
        seen.add(name)
        parts = name.split('/')
        for i in range(1, len(parts) + 1):
            prefix = '/'.join(parts[:i])
            row = entries.get(prefix, {})
            if row.get('type') == 'symlink':
                name = '/'.join([link_target(prefix, row['target'])] + parts[i:])
                break
        else:
            return entries.get(name, {}).get('type') == 'file'
    return False


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archive', type=Path)
    args = parser.parse_args()
    manifest = verify(args.archive)
    entries = {row['path']: row for row in manifest['files']}
    missing, weak = set(), set()
    checked = 0
    with tarfile.open(args.archive, 'r|gz') as archive:
        for item in archive:
            if not item.isfile():
                continue
            source = archive.extractfile(item)
            magic = source.read(4)
            if magic not in (b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca'):
                continue
            checked += 1
            for library, optional in links(magic + source.read()):
                if library.startswith('@loader_path/'):
                    candidate = link_target(item.name, library[len('@loader_path/'):])
                elif library.startswith('/'):
                    candidate = library
                else:
                    candidate = None
                if candidate and resolve(candidate, entries):
                    continue
                (weak if optional else missing).add((item.name, library))
    for binary, library in sorted(missing):
        print(f'MISSING {binary}: {library}')
    for library in sorted({library for _, library in weak}):
        print(f'optional library absent: {library}')
    print(f'checked {checked} binaries; {len(missing)} missing or unresolved required links')
    raise SystemExit(bool(missing))


if __name__ == '__main__':
    main()
