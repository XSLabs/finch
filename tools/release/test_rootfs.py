#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Check install ownership, repeatable archives and unsafe path rejection."""
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
import struct

import mkrootfs as pack
import verifyrootfs as checker
from check_libraries import links, resolve


class RootfsTests(unittest.TestCase):
    def test_installed_test_bundle_is_not_packaged(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            stage = root / 'stage'
            accounts = stage / 'private/etc'
            accounts.mkdir(parents=True)
            (accounts / 'master.passwd').write_text(
                'root:*:0:0::0:0:Root:/var/root:/bin/sh\n')
            bundle = stage / 'usr/lib/system/xctests.xctest/Contents/MacOS'
            bundle.mkdir(parents=True)
            (bundle / 'xctests').write_bytes(b'developer test program')
            library = stage / 'usr/lib/system/libsystem_notify.dylib'
            library.write_bytes(b'system library')
            overlay = root / 'overlay.txt'
            overlay.write_text('')
            entries = pack.collect(stage, overlay, root)
            self.assertIn('usr/lib/system/libsystem_notify.dylib', entries)
            self.assertFalse(any('.xctest' in name for name in entries))

    def test_notifyd_release_account_is_locked_and_has_its_own_group(self):
        templates = Path(__file__).resolve().parents[2] / 'userland/release/etc'
        users = [line.split(':') for line in (templates / 'master.passwd').read_text().splitlines()
                 if line and not line.startswith('#')]
        groups = [line.split(':') for line in (templates / 'group').read_text().splitlines()
                  if line and not line.startswith('#')]
        self.assertEqual([row for row in users if row[0] == '_notifyd'],
                         [['_notifyd', '*', '11', '11', '', '0', '0',
                           'Notification Service', '/var/empty', '/sbin/nologin']])
        self.assertEqual([row for row in groups if row[0] == '_notifyd'],
                         [['_notifyd', '*', '11', '']])
        self.assertEqual([row[0] for row in users if int(row[2]) == 11], ['_notifyd'])
        self.assertEqual([row[0] for row in groups if int(row[2]) == 11], ['_notifyd'])
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            account_dir = root / 'stage/private/etc'
            account_dir.mkdir(parents=True)
            for filename in ('master.passwd', 'group'):
                (account_dir / filename).write_bytes((templates / filename).read_bytes())
            overlay = root / 'overlay.txt'
            overlay.write_text('')
            entries = pack.collect(root / 'stage', overlay, root)
            self.assertIn(b'_notifyd:*:11:11:Notification Service:/var/empty:/sbin/nologin\n',
                          entries['private/etc/passwd']['data'])
            self.assertEqual(entries['private/etc/master.passwd']['mode'], 0o600)
            self.assertEqual(entries['private/etc/passwd']['mode'], 0o644)
            self.assertEqual(entries['private/etc/group']['mode'], 0o644)

    def test_verifier_rejects_public_password_hash(self):
        entries = {}
        for name in ('private', 'private/etc', 'usr', 'usr/share', 'usr/share/finch'):
            entries[name] = pack.record(name, 'directory', 0o755)
        path = 'private/etc/passwd'
        entries[path] = pack.record(path, 'file', 0o644,
            data=b'reader:private-hash-marker:501:20:Reader:/Users/reader:/bin/zsh\n')
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'payload.tar.gz'
            pack.archive(entries, output, 0, {})
            with self.assertRaisesRegex(ValueError, 'unsafe password field'):
                checker.verify(output, require_system=False)

    def test_public_account_file_does_not_expose_password_hashes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            stage = root / 'stage'
            account_dir = stage / 'private/etc'
            account_dir.mkdir(parents=True)
            master = account_dir / 'master.passwd'
            master.write_text('reader:private-hash-marker:501:20::0:0:Reader:/Users/reader:/bin/zsh\n'
                              'locked:*:502:20::0:0:Locked:/Users/locked:/bin/false\n')
            overlay = root / 'overlay.txt'
            overlay.write_text('')
            entries = pack.collect(stage, overlay, root)
            public = entries['private/etc/passwd']['data']
            self.assertNotIn(b'private-hash-marker', public)
            self.assertEqual(public, b'reader:*:501:20:Reader:/Users/reader:/bin/zsh\n'
                                     b'locked:*:502:20:Locked:/Users/locked:/bin/false\n')
            self.assertIn('private-hash-marker', master.read_text())
            self.assertEqual(entries['private/etc/master.passwd']['mode'], 0o600)
            self.assertEqual(entries['private/etc/passwd']['mode'], 0o644)

    def test_login_settings_require_packaged_modules(self):
        self.assertEqual(checker.read_pam_modules('auth required pam_unix.so\n'), {'usr/lib/pam/pam_unix.so'})
        with self.assertRaises(ValueError):
            checker.read_pam_modules('auth include external-stack\n')
        entries = {}
        for name in ('usr', 'usr/share', 'usr/share/finch', 'private', 'private/etc', 'private/etc/pam.d'):
            entries[name] = pack.record(name, 'directory', 0o755)
        path = 'private/etc/pam.d/login'
        entries[path] = pack.record(path, 'file', 0o644, data=b'auth required pam_missing.so\n')
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'payload.tar.gz'
            pack.archive(entries, output, 0, {})
            with self.assertRaisesRegex(ValueError, 'missing PAM module'):
                checker.verify(output, require_system=False)

    def test_library_links_and_framework_aliases(self):
        commands = []
        for command, name in ((0xc, b'/usr/lib/required.dylib'),
                              (0x80000018, b'/usr/lib/optional.dylib')):
            string = name + b'\0'
            commands.append(struct.pack('<IIIIII', command, 24 + len(string), 24, 0, 0, 0) + string)
        body = b''.join(commands)
        header = struct.pack('<IIIIIIII', 0xfeedfacf, 0x100000c, 2, 2, 2, len(body), 0, 0)
        self.assertEqual(links(header + body), [('/usr/lib/required.dylib', False),
                                              ('/usr/lib/optional.dylib', True)])
        with self.assertRaises(ValueError):
            links(header + body[:-1])
        entries = {'Framework/Current': {'type': 'symlink', 'target': 'A'},
                   'Framework/A/Library': {'type': 'file'},
                   'Framework/A': {'type': 'directory'}}
        self.assertTrue(resolve('/Framework/Current/Library', entries))
        self.assertFalse(resolve('/Framework/Current/Missing', entries))
        self.assertFalse(resolve('/Framework/A', entries))

    def test_verifier_rejects_changed_payload_and_unsafe_metadata(self):
        entries = {'file': pack.record('file', 'file', 0o644, data=b'original')}
        for name in ('usr', 'usr/share', 'usr/share/finch'):
            entries[name] = pack.record(name, 'directory', 0o755)
        with tempfile.TemporaryDirectory() as directory:
            original = Path(directory) / 'original.tar.gz'
            pack.archive(entries, original, 0, {})
            checker.verify(original, require_system=False)
            for change in ('bytes', 'owner', 'setuid', 'writable', 'absolute', 'duplicate', 'no_manifest'):
                changed = Path(directory) / f'{change}.tar.gz'
                with tarfile.open(original) as source, tarfile.open(changed, 'w:gz') as target:
                    for item in source:
                        if change == 'no_manifest' and item.name == pack.MANIFEST:
                            continue
                        data = source.extractfile(item).read() if item.isfile() else None
                        if item.name == 'file':
                            if change == 'bytes':
                                data = b'modified'
                            elif change == 'owner':
                                item.uid = 501
                            elif change == 'setuid':
                                item.mode = 0o4755
                            elif change == 'writable':
                                item.mode = 0o666
                            elif change == 'absolute':
                                item.name = '/file'
                        target.addfile(item, io.BytesIO(data) if data is not None else None)
                        if change == 'duplicate' and item.name == 'file':
                            target.addfile(item, io.BytesIO(data))
                with self.subTest(change=change), self.assertRaises(ValueError):
                    checker.verify(changed, require_system=False)

    def test_owners_modes_and_repeatable_bytes(self):
        entries = {
            'usr/bin/at': pack.record('usr/bin/at', 'file', 0o7777, data=b'at binary'),
            'usr/bin/ordinary': pack.record('usr/bin/ordinary', 'file', 0o4755, data=b'ordinary'),
            'private/etc/master.passwd': pack.record('private/etc/master.passwd', 'file', 0o644, data=b'root:*'),
            'private/tmp': pack.record('private/tmp', 'directory', 0o755),
            'usr/lib/cron/jobs': pack.record('usr/lib/cron/jobs', 'directory', 0o755),
        }
        with tempfile.TemporaryDirectory() as directory:
            one, two = Path(directory) / 'one.tar.gz', Path(directory) / 'two.tar.gz'
            manifest = pack.archive(entries, one, 123, {})
            pack.archive(entries, two, 123, {})
            self.assertEqual(one.read_bytes(), two.read_bytes())
            with tarfile.open(one) as tar:
                self.assertEqual(tar.getmember('usr/bin/at').mode, 0o4555)
                self.assertEqual(tar.getmember('usr/bin/ordinary').mode, 0o755)
                self.assertEqual(tar.getmember('usr/bin/at').uid, 0)
                self.assertEqual(tar.getmember('private/etc/master.passwd').mode, 0o600)
                self.assertEqual(tar.getmember('private/tmp').mode, 0o1777)
                self.assertEqual(tar.getmember('usr/lib/cron/jobs').uid, 1)
                self.assertEqual(tar.getmember('usr/lib/cron/jobs').gid, 1)
                self.assertEqual(tar.extractfile(pack.MANIFEST).read(), manifest)
                self.assertEqual(tar.extractfile('usr/bin/at').read(), b'at binary')
            self.assertFalse(json.loads(manifest)['bootable'])
            self.assertFalse(json.loads(manifest)['signed'])

    def test_links_stay_inside_root_and_resolve(self):
        entries = {
            'private': pack.record('private', 'directory', 0o755),
            'private/etc': pack.record('private/etc', 'directory', 0o755),
            'private/etc/group': pack.record('private/etc/group', 'file', 0o644, data=b'group'),
            'etc': pack.record('etc', 'symlink', 0o777, target='private/etc'),
            'groups': pack.record('groups', 'symlink', 0o777, target='/etc/group'),
        }
        pack.check_links(entries)
        for target in ('../outside', '/missing', 'groups'):
            entries['groups']['target'] = target
            with self.assertRaises(ValueError):
                pack.check_links(entries)

    def test_bad_paths_rejected(self):
        for path in ('', '../outside', 'usr/../../outside', 'usr//bin', 'usr/./bin', 'bad\x00name'):
            with self.assertRaises(ValueError):
                pack.safe_path(path)

    def test_source_change_keeps_previous_archive(self):
        class ChangingFile:
            calls = 0
            def read_bytes(self):
                self.calls += 1
                return b'before' if self.calls == 1 else b'after'
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'root.tar.gz'
            output.write_bytes(b'existing archive')
            with self.assertRaises(ValueError):
                pack.archive({'file': pack.record('file', 'file', 0o644, source=ChangingFile())}, output, 0, {})
            self.assertEqual(output.read_bytes(), b'existing archive')
            self.assertEqual(sorted(p.name for p in output.parent.iterdir()), ['root.tar.gz'])


if __name__ == '__main__':
    unittest.main()
