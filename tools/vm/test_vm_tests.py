#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Keep a successful process exit from hiding an unchecked comparison."""
import hashlib
import importlib.util
import json
from pathlib import Path
import unittest
import subprocess
import tempfile
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('vm_tests', Path(__file__).with_name('vm-tests.py'))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class TestResultChecks(unittest.TestCase):
    def test_video_tolerance_is_bounded_and_does_not_hide_other_changes(self):
        expected = 'decoded frames 4 pixels 12288\ndecoded RGB means r=93.64 g=94.02 b=93.59\n'
        close = 'decoded frames 4 pixels 12288\ndecoded RGB means r=104.89 g=104.89 b=104.89\n'
        self.assertTrue(runner.video_matches(expected, close))
        self.assertFalse(runner.video_matches(expected, close.replace('104.89', '200.00')))
        self.assertFalse(runner.video_matches(expected, close.replace('frames 4', 'frames 3')))
        self.assertFalse(runner.video_matches(expected, close + 'extra output\n'))
        self.assertFalse(runner.video_matches(expected, close.replace('r=104.89', 'r=nan')))
        self.assertFalse(runner.video_matches('', ''))

    def test_borrowed_marker_requires_guest_output(self):
        self.assertEqual(runner.borrowed_components('echo "VMTBORROWED|sandbox"\n'), set())
        self.assertEqual(runner.borrowed_components('\nVMTBORROWED|sandbox\r\r\n'), {'sandbox'})

    def test_borrowed_sandbox_cannot_pass_or_be_excused(self):
        inputs = {name: Path('/vm-inputs/' + name.lower()) for name in runner.VM_INPUTS}
        hashes = {name: name.lower() * 8 for name in runner.VM_INPUTS}

        def guest_run(*args, **kwargs):
            for name, path in inputs.items():
                self.assertEqual(kwargs['env'][name], str(path))
            kwargs['stdout'].write(b'VMTBORROWED|sandbox\nVMT|libsandbox-test|0|0 0\n')
            return subprocess.CompletedProcess(args, 0)

        offline = runner.parse_display_snapshot('Graphics/Displays:\n\n    Apple M4:\n      Type: GPU\n')
        with tempfile.TemporaryDirectory(dir=runner.ROOT / "build") as folder, \
                patch.object(runner.sys, 'argv', ['vm-tests.py', 'libsandbox-test']), \
                patch.object(runner, 'plan', return_value=([('libsandbox-test', 'exit', '', None)], {})), \
                patch.object(runner, 'OUTPUTS', Path(folder)), \
                patch.object(runner, 'resolve_vm_inputs', return_value=inputs), \
                patch.object(runner, 'vm_input_hashes', return_value=hashes), \
                patch.object(runner, 'capture_display_snapshot', side_effect=[offline, offline]), \
                patch.object(runner, 'exceptions', return_value={'libsandbox-test': 'known issue'}), \
                patch.object(runner.subprocess, 'run', side_effect=guest_run), \
                patch('builtins.print') as output:
            self.assertEqual(runner.main(), 1)
            record = json.loads((Path(folder) / 'run.json').read_text())
            self.assertEqual(record['inputsBefore'][0]['sha256'], hashes['KC'])
            self.assertEqual(record['inputsAfter'][0]['sha256'], hashes['KC'])
            self.assertTrue(record['inputsUnchanged'])
            self.assertFalse(record['appleReferenceDisplay']['before']['onlineScreenPresent'])
            self.assertFalse(record['appleReferenceDisplay']['after']['onlineScreenPresent'])
        self.assertTrue(any('not verified: base image sandbox library' in str(call) for call in output.call_args_list))

    def test_main_records_offline_reference_warning_and_keeps_comparing(self):
        inputs = {name: Path('/vm-inputs/' + name.lower()) for name in runner.VM_INPUTS}
        hashes = {name: name.lower() * 8 for name in runner.VM_INPUTS}
        offline = runner.parse_display_snapshot('Graphics/Displays:\n    Apple M4:\n      Type: GPU\n')

        def guest_run(*args, **kwargs):
            kwargs['stdout'].write(b'VMT|runtime-test|0|0 0\n')
            return subprocess.CompletedProcess(args, 0)

        with tempfile.TemporaryDirectory(dir=runner.ROOT / "build") as folder, \
                patch.object(runner.sys, 'argv', ['vm-tests.py']), \
                patch.object(runner, 'plan', return_value=([('runtime-test', 'compare', '', None)], {})), \
                patch.object(runner, 'OUTPUTS', Path(folder)), \
                patch.object(runner, 'resolve_vm_inputs', return_value=inputs), \
                patch.object(runner, 'vm_input_hashes', return_value=hashes), \
                patch.object(runner, 'capture_display_snapshot', side_effect=[offline, offline]), \
                patch.object(runner, 'reference_output', return_value=(b'expected\n', None)) as reference, \
                patch.object(runner, 'cksum', return_value='0 0'), \
                patch.object(runner, 'exceptions', return_value={}), \
                patch.object(runner.subprocess, 'run', side_effect=guest_run), \
                patch('builtins.print') as output:
            self.assertEqual(runner.main(), 0)
            reference.assert_called_once_with('runtime-test', '')
            record = json.loads((Path(folder) / 'run.json').read_text())
            self.assertEqual(record['appleReferenceDisplay']['contextChanged'], False)
            self.assertTrue(any('No online screen was confirmed' in warning
                                for warning in record['appleReferenceDisplay']['warnings']))
        self.assertTrue(any('Apple reference display warning' in str(call) for call in output.call_args_list))

    def test_vm_input_defaults_match_run_sh_build_image_choice(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            firmware = root / 'third_party/darwin-vm/firmware'
            firmware.mkdir(parents=True)
            for name in ('bootkc', 'ramdisk.dmg', 'ramdisk.tc'):
                (firmware / name).write_bytes(name.encode())
            with patch.object(runner, 'ROOT', root):
                base = runner.resolve_vm_inputs({})
                self.assertEqual(base['RAMDISK'], (firmware / 'ramdisk.dmg').resolve())
                self.assertEqual(base['TC'], (firmware / 'ramdisk.tc').resolve())

                built = root / 'build/vm'
                built.mkdir(parents=True)
                (built / 'ramdisk.dmg').write_bytes(b'built ramdisk')
                (built / 'ramdisk.tc').write_bytes(b'built trust cache')
                finch = runner.resolve_vm_inputs({})
                self.assertEqual(finch['RAMDISK'], (built / 'ramdisk.dmg').resolve())
                self.assertEqual(finch['TC'], (built / 'ramdisk.tc').resolve())

    def test_vm_input_overrides_are_rooted_and_normalized(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            files = {}
            for name in runner.VM_INPUTS:
                path = root / (name.lower() + '.img')
                path.write_bytes(name.encode())
                files[name] = path
            with patch.object(runner, 'ROOT', root):
                resolved = runner.resolve_vm_inputs({
                    'KC': 'kc.img', 'RAMDISK': str(files['RAMDISK']), 'TC': 'tc.img',
                })
                self.assertEqual(resolved, {name: path.resolve() for name, path in files.items()})
                env = runner.vm_environment(resolved, {'KC': 'wrong', 'CUSTOM': 'kept'})
                for name, path in resolved.items():
                    self.assertEqual(env[name], str(path))
                self.assertEqual(env['CUSTOM'], 'kept')

    def test_boot_options_record_defaults_and_explicit_guest_mode(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with patch.object(runner, 'ROOT', root):
                base = runner.vm_boot_options({})
                self.assertEqual(base['FINCH_INIT']['value'], '0')
                self.assertEqual(base['FINCH_INIT']['source'], 'run.sh default (no built Finch ramdisk)')
                self.assertFalse(base['FINCH_DEV_CONSOLE']['used'])
                self.assertEqual(base['BOOT_ARGS_EXTRA']['value'], '')
                self.assertIn('default', base['BOOT_ARGS_EXTRA']['source'])

                built = root / 'build/vm'
                built.mkdir(parents=True)
                (built / 'ramdisk.dmg').write_bytes(b'built image')
                default_finch = runner.vm_boot_options({})
                self.assertEqual(default_finch['FINCH_INIT']['value'], '1')
                self.assertTrue(default_finch['FINCH_DEV_CONSOLE']['enabled'])

                aio_new_workq = runner.vm_boot_options({
                    'FINCH_INIT': '1',
                    'FINCH_DEV_CONSOLE': '0',
                    'BOOT_ARGS_EXTRA': 'aio_new_workq=0',
                })
                self.assertEqual(aio_new_workq['FINCH_INIT']['source'], 'environment')
                self.assertEqual(aio_new_workq['FINCH_DEV_CONSOLE']['value'], '0')
                self.assertFalse(aio_new_workq['FINCH_DEV_CONSOLE']['enabled'])
                self.assertEqual(aio_new_workq['BOOT_ARGS_EXTRA']['value'], 'aio_new_workq=0')
                self.assertEqual(aio_new_workq['BOOT_ARGS_EXTRA']['source'], 'environment')

    def test_missing_vm_input_is_rejected_before_launch(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            firmware = root / 'third_party/darwin-vm/firmware'
            firmware.mkdir(parents=True)
            (firmware / 'bootkc').write_bytes(b'kernel')
            (firmware / 'ramdisk.dmg').write_bytes(b'ramdisk')
            with patch.object(runner, 'ROOT', root):
                with self.assertRaisesRegex(ValueError, 'TC input is missing'):
                    runner.resolve_vm_inputs({})

                built = root / 'build/vm'
                built.mkdir(parents=True)
                (built / 'ramdisk.dmg').write_bytes(b'built ramdisk')
                with self.assertRaisesRegex(ValueError, 'TC input is missing'):
                    runner.resolve_vm_inputs({})

    def test_vm_input_hashes_read_files_in_chunks(self):
        with tempfile.TemporaryDirectory() as temporary:
            inputs = {}
            for name in runner.VM_INPUTS:
                path = Path(temporary) / name.lower()
                path.write_bytes((name * 50000).encode())
                inputs[name] = path
            expected = {
                name: hashlib.sha256(path.read_bytes()).hexdigest()
                for name, path in inputs.items()
            }
            self.assertEqual(runner.vm_input_hashes(inputs), expected)

    def test_script_runner_records_inherited_and_script_specific_images(self):
        vm_inputs = {name: Path('/vm-inputs/' + name.lower()) for name in runner.VM_INPUTS}
        run_env = runner.vm_environment(vm_inputs, {'KEEP': 'yes'})
        override = Path('/vm-inputs/login/ramdisk.dmg')
        trust_cache = Path('/vm-inputs/login/ramdisk.tc')
        ramdisk_hash = 'a' * 64
        trust_cache_hash = 'b' * 64
        output = ('VMTIMAGE|RAMDISK|%s|%s\n' % (override, ramdisk_hash) +
                  'VMTIMAGE|TC|%s|%s\nscript passed\n' % (trust_cache, trust_cache_hash))
        result = subprocess.CompletedProcess(['test-keychain.sh'], 0, output, '')
        with patch.object(runner, 'ROOT', Path('/finch')), \
                patch.object(runner, 'SCRIPT_IMAGE_OVERRIDES', {
                    'tools/vm/test-keychain.sh': {'RAMDISK': override, 'TC': trust_cache},
                }), \
                patch.object(runner.subprocess, 'run', return_value=result) as run, \
                patch.object(runner, 'vm_input_hashes', return_value={
                    'RAMDISK': ramdisk_hash, 'TC': trust_cache_hash,
                }):
            completed, record = runner.run_test_script('tools/vm/test-keychain.sh', run_env, vm_inputs)
        self.assertIs(completed, result)
        self.assertEqual(run.call_args.kwargs['env']['KC'], str(vm_inputs['KC']))
        self.assertEqual(record['inheritedInputs']['TC'], str(vm_inputs['TC']))
        self.assertEqual(record['imageOverrides']['RAMDISK']['path'], str(override))
        self.assertEqual(record['imageOverrides']['RAMDISK']['sha256AtLaunch'], ramdisk_hash)
        self.assertEqual(record['imageOverrides']['RAMDISK']['sha256AfterScript'], ramdisk_hash)
        self.assertTrue(record['imageOverrides']['RAMDISK']['verifiedAtLaunch'])
        self.assertTrue(record['imageOverrides']['RAMDISK']['unchangedAfterScript'])
        self.assertTrue(record['imageEvidenceValid'])
        self.assertEqual(record['imageEvidenceErrors'], [])

    def test_script_image_markers_require_exact_unique_records(self):
        images = {
            'RAMDISK': Path('/vm-inputs/login/ramdisk.dmg'),
            'TC': Path('/vm-inputs/login/ramdisk.tc'),
        }
        valid = ('VMTIMAGE|RAMDISK|%s|%s\nVMTIMAGE|TC|%s|%s\n' % (
            images['RAMDISK'], 'a' * 64, images['TC'], 'b' * 64))
        records, errors = runner.parse_script_image_markers(valid, images)
        self.assertEqual(errors, [])
        self.assertEqual(records['RAMDISK']['sha256'], 'a' * 64)
        self.assertEqual(records['TC']['sha256'], 'b' * 64)

        cases = {
            'missing': ('VMTIMAGE|RAMDISK|%s|%s\n' % (images['RAMDISK'], 'a' * 64),
                        'missing VMTIMAGE record for TC'),
            'malformed': (valid + 'VMTIMAGE|TC|too-few-fields\n', 'malformed VMTIMAGE record'),
            'indented marker': (valid + '  VMTIMAGE|RAMDISK|%s|%s\n' % (
                images['RAMDISK'], 'a' * 64), 'malformed VMTIMAGE record'),
            'duplicate': (valid + 'VMTIMAGE|RAMDISK|%s|%s\n' % (images['RAMDISK'], 'a' * 64),
                          'duplicate VMTIMAGE record for RAMDISK'),
            'conflicting': (valid + 'VMTIMAGE|RAMDISK|%s|%s\n' % (images['RAMDISK'], 'c' * 64),
                            'duplicate VMTIMAGE record for RAMDISK'),
            'wrong path': (valid.replace(str(images['TC']), '/wrong/ramdisk.tc'),
                           'VMTIMAGE path for TC does not match'),
            'bad hash': (valid.replace('b' * 64, 'bad'),
                         'VMTIMAGE hash for TC is not a SHA-256 value'),
            'unknown name': (valid + 'VMTIMAGE|EXTRA|/tmp/extra|%s\n' % ('c' * 64),
                             'unexpected VMTIMAGE name'),
        }
        for label, (output, message) in cases.items():
            with self.subTest(label=label):
                records, errors = runner.parse_script_image_markers(output, images)
                self.assertTrue(any(message in error for error in errors), errors)
                if label in ('duplicate', 'conflicting'):
                    self.assertNotIn('RAMDISK', records)

    def test_script_image_change_after_launch_invalidates_evidence(self):
        vm_inputs = {name: Path('/vm-inputs/' + name.lower()) for name in runner.VM_INPUTS}
        run_env = runner.vm_environment(vm_inputs)
        override = Path('/vm-inputs/login/ramdisk.dmg')
        trust_cache = Path('/vm-inputs/login/ramdisk.tc')
        launch_ramdisk = 'a' * 64
        launch_tc = 'b' * 64
        output = ('VMTIMAGE|RAMDISK|%s|%s\n' % (override, launch_ramdisk) +
                  'VMTIMAGE|TC|%s|%s\n' % (trust_cache, launch_tc))
        result = subprocess.CompletedProcess(['test-keychain.sh'], 0, output, '')
        with patch.object(runner, 'ROOT', Path('/finch')), \
                patch.object(runner, 'SCRIPT_IMAGE_OVERRIDES', {
                    'tools/vm/test-keychain.sh': {'RAMDISK': override, 'TC': trust_cache},
                }), \
                patch.object(runner.subprocess, 'run', return_value=result), \
                patch.object(runner, 'vm_input_hashes', return_value={
                    'RAMDISK': 'c' * 64, 'TC': launch_tc,
                }):
            _, record = runner.run_test_script('tools/vm/test-keychain.sh', run_env, vm_inputs)
        self.assertFalse(record['imageOverrides']['RAMDISK']['unchangedAfterScript'])
        self.assertTrue(record['imageOverrides']['TC']['unchangedAfterScript'])
        self.assertFalse(record['imageEvidenceValid'])
        self.assertTrue(any('RAMDISK image changed after guest launch' in error
                            for error in record['imageEvidenceErrors']))

    def test_attached_1x_display_enables_host_display_exceptions(self):
        profile = '''
        Graphics/Displays:
          Apple M4:
            Type: GPU
            Displays:
              External Display:
                Resolution: 1920 x 1080
                UI Looks like: 1920 x 1080 @ 60.00Hz
                Online: Yes
              Built-in Display:
                Resolution: 5120 x 2880 Retina
                UI Looks like: 2560 x 1440 @ 60.00Hz
                Main Display: Yes
                Online: Yes
        '''
        snapshot = runner.parse_display_snapshot(profile)
        self.assertEqual(snapshot['screenCount'], 2)
        self.assertEqual(snapshot['onlineScreenCount'], 2)
        self.assertFalse(snapshot['mainDisplay1x'])
        self.assertTrue(snapshot['attached1x'])
        self.assertEqual(snapshot['screens'][0]['scale'], [1.0, 1.0])
        self.assertEqual(snapshot['screens'][1]['scale'], [2.0, 2.0])
        self.assertEqual(runner.display_1x_state(profile), (False, True))
        with patch.object(runner, 'EXCEPTIONS', Path('/missing/vm-test-exceptions.txt')):
            known = runner.exceptions(snapshot)
        self.assertEqual(known['nib-test'],
                         "1x display: Apple's AppKit restores the nib window to an attached 1x screen; Finch has no screen list")

    def test_offline_display_snapshot_warns_without_changing_result_checks(self):
        output = '''
        Graphics/Displays:
          Apple M4:
            Chipset Model: Apple M4
            Type: GPU
        '''
        offline = runner.parse_display_snapshot(output)
        self.assertTrue(offline['sourceAvailable'])
        self.assertEqual(offline['screenCount'], 0)
        self.assertEqual(offline['onlineScreenCount'], 0)
        self.assertFalse(offline['onlineScreenPresent'])
        self.assertEqual(runner.display_1x_state(output), (False, False))
        warnings = runner.apple_reference_display_warnings(offline, offline, 2)
        self.assertEqual(len(warnings), 1)
        self.assertIn('No online screen', warnings[0])
        tests, _ = runner.plan({'libsystem-test'})
        self.assertEqual(tests, [('libsystem-test', 'exit', '', None)])

    def test_stable_display_context_has_no_warning(self):
        profile = '''
        Graphics/Displays:
          Apple M4:
            Displays:
              Built-in Display:
                Resolution: 5120 x 2880 Retina
                UI Looks like: 2560 x 1440 @ 60.00Hz
                Main Display: Yes
                Online: Yes
        '''
        before = runner.parse_display_snapshot(profile)
        after = runner.parse_display_snapshot(profile)
        self.assertFalse(runner.display_context_changed(before, after))
        self.assertEqual(runner.apple_reference_display_warnings(before, after, 1), [])

    def test_changed_or_unreadable_display_context_is_recorded_as_warning(self):
        online = runner.parse_display_snapshot('''
        Resolution: 5120 x 2880 Retina
        UI Looks like: 2560 x 1440 @ 60.00Hz
        Main Display: Yes
        Online: Yes
        ''')
        offline = runner.parse_display_snapshot('Graphics/Displays:\n    Apple M4:\n      Type: GPU\n')
        self.assertTrue(runner.display_context_changed(online, offline))
        warnings = runner.apple_reference_display_warnings(online, offline, 1)
        self.assertTrue(any('No online screen' in warning for warning in warnings))
        self.assertTrue(any('Screen context changed' in warning for warning in warnings))

        unreadable = runner.parse_display_snapshot(None)
        self.assertIsNone(runner.display_context_changed(online, unreadable))
        self.assertTrue(any('Could not read screen state' in warning
                            for warning in runner.apple_reference_display_warnings(online, unreadable, 1)))

    def test_main_1x_display_is_detected(self):
        profile = '''
        Resolution: 1920 x 1080
        UI Looks like: 1920 x 1080 @ 60.00Hz
        Main Display: Yes
        Online: Yes
        '''
        self.assertEqual(runner.display_1x_state(profile), (True, True))

    def test_help_does_not_start_tests(self):
        with patch.object(runner.sys, 'argv', ['vm-tests.py', '--help']), \
                patch.object(runner, 'plan') as plan:
            with self.assertRaises(SystemExit) as result:
                runner.main()
        self.assertEqual(result.exception.code, 0)
        plan.assert_not_called()

    def test_unknown_option_does_not_start_tests(self):
        with patch.object(runner.sys, 'argv', ['vm-tests.py', '--typo']), \
                patch.object(runner, 'plan') as plan:
            with self.assertRaises(SystemExit) as result:
                runner.main()
        self.assertEqual(result.exception.code, 2)
        plan.assert_not_called()

    def test_print_only_tests_compare_their_results(self):
        tests, _ = runner.plan({'appkit-misc2-test', 'forward-test', 'runtime-test', 'ws-test'})
        modes = {name: (kind, expected) for name, kind, _, expected in tests}
        for name in ('appkit-misc2-test', 'forward-test', 'runtime-test'):
            self.assertEqual(modes[name], ('compare', None))
        self.assertEqual(modes['ws-test'], ('expected', 'userland/tests/ws-test.expected'))

    def test_new_test_cannot_silently_pass_from_its_exit_code(self):
        with patch.object(runner, 'overlay', return_value={
            'build/userland/finch-new-test': '/usr/local/bin/finch-new-test',
        }):
            with self.assertRaisesRegex(ValueError, 'no result check for new-test'):
                runner.plan(set())

    def test_existing_self_check_still_runs(self):
        tests, _ = runner.plan({'libsystem-test'})
        self.assertEqual(tests, [('libsystem-test', 'exit', '', None)])

    def test_all_current_vm_tests_have_a_result_check(self):
        tests, _ = runner.plan(set())
        self.assertTrue(tests)
        self.assertEqual(len(tests), len({test[0] for test in tests}))

    def test_reference_needs_more_than_its_library_banner(self):
        result = subprocess.CompletedProcess([], 0, b'Foundation: Apple\n\n', b'')
        with patch.object(runner.subprocess, 'run', return_value=result):
            data, error = runner.reference_output('runtime-test', '')
        self.assertIsNone(data)
        self.assertIn('no comparison output', error)

    def test_reference_uses_apple_and_a_private_preferences_home(self):
        seen = {}
        def reference(*args, **kwargs):
            seen.update(kwargs['env'])
            self.assertTrue(Path(seen['CFFIXED_USER_HOME']).is_dir())
            return subprocess.CompletedProcess([], 0, b'CoreFoundation: Apple\nvalue=1\n', b'')
        with patch.dict(runner.os.environ, {'DYLD_LIBRARY_PATH': '/wrong', 'FINCH_THEME': 'wrong',
                                          'CFFIXED_USER_HOME': '/wrong'}), \
                patch.object(runner.subprocess, 'run', side_effect=reference):
            data, error = runner.reference_output('cf-preferences-container-test', '')
        self.assertEqual(data, b'value=1\n')
        self.assertIsNone(error)
        self.assertNotIn('DYLD_LIBRARY_PATH', seen)
        self.assertNotIn('FINCH_THEME', seen)
        self.assertFalse(Path(seen['CFFIXED_USER_HOME']).exists())

    def test_stalled_reference_is_a_failure(self):
        with patch.object(runner.subprocess, 'run', side_effect=subprocess.TimeoutExpired([], 1)) as run:
            data, error = runner.reference_output('runtime-test', '')
        self.assertIsNone(data)
        self.assertIn('exceeded', error)
        self.assertEqual(run.call_args.kwargs['timeout'], runner.LIMIT)


if __name__ == '__main__':
    unittest.main()
