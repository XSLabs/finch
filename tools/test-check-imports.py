#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Unreadable images and wrong architectures must never pass the app check."""
import importlib.util
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location('check_imports', Path(__file__).with_name('check-imports.py'))
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


def result(body='', code=0, error=''):
    return subprocess.CompletedProcess([], code, body, error)


class ImportChecks(unittest.TestCase):
    def setUp(self):
        checker._exports.clear()

    def test_failed_inspection_does_not_mean_no_imports(self):
        with patch.object(checker.subprocess, 'run', return_value=result(code=1, error='bad image')):
            with self.assertRaisesRegex(checker.InspectionError, 'bad image'):
                checker.check('unreadable')

    def test_failed_tool_with_partial_output_is_rejected(self):
        body = 'image [arm64e]:\n    -imports:\n'
        with patch.object(checker.subprocess, 'run', return_value=result(body, 1, 'truncated')):
            with self.assertRaisesRegex(checker.InspectionError, 'truncated'):
                checker.run('dyld_info', '-arch', 'arm64e', '-imports', 'image')

    def test_versioned_single_slice_fallback(self):
        body = 'image [arm64e.v1]:\n    -imports:\n'
        with patch.object(checker.subprocess, 'run', side_effect=[result(), result(body)]) as command:
            self.assertEqual(checker.run('dyld_info', '-arch', 'arm64e', '-imports', 'image'), body)
            self.assertEqual(command.call_args.args[0], ('dyld_info', '-imports', 'image'))

    def test_fallback_never_combines_architectures(self):
        for body in ('image [x86_64]:\n    -imports:\n',
                     'image [arm64e.v1]:\n    -imports:\nimage [x86_64]:\n    -imports:\n',
                     '', 'unexpected output\nwith no section\n'):
            with self.subTest(body=body), patch.object(checker.subprocess, 'run',
                    side_effect=[result(), result(body)]):
                with self.assertRaises(checker.InspectionError):
                    checker.run('dyld_info', '-arch', 'arm64e', '-imports', 'image')

    def test_missing_tool_is_not_silently_accepted(self):
        with patch.object(checker.subprocess, 'run', side_effect=FileNotFoundError('dyld_info')):
            with self.assertRaises(FileNotFoundError):
                checker.check('image')

    def test_export_cache_is_separate_for_each_build(self):
        def inspection(*args):
            if args[-2] == '-linked_dylibs':
                return 'image [arm64e]:\n    -linked_dylibs:\n'
            name = '_first' if args[-1].startswith('/first/') else '_second'
            return f'image [arm64e]:\n    -exports:\n    0x0000 {name}\n'

        with patch.object(checker, 'image_path', side_effect=lambda root, name: root + name), \
                patch.object(checker, 'run', side_effect=inspection):
            self.assertEqual(checker.exports_of('/first', '/libExample.dylib'), {'_first'})
            self.assertEqual(checker.exports_of('/second', '/libExample.dylib'), {'_second'})


if __name__ == '__main__':
    unittest.main()
