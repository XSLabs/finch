#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Check how the VM runner spots notifyd exits in the guest log."""
import importlib.util
from pathlib import Path
import unittest


spec = importlib.util.spec_from_file_location(
    'vm_tests', Path(__file__).with_name('vm-tests.py'))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class NotifydExitMessages(unittest.TestCase):
    def test_finds_signal_death_even_after_another_log_message(self):
        text = ('AMFI: Denying core dump for pid 42 (notifyd)'
                'finch-init: com.apple.notifyd: killed by signal 6\r\r\n')
        self.assertEqual(
            runner.notifyd_exit_messages(text),
            ['finch-init: com.apple.notifyd: killed by signal 6'])

    def test_finds_nonzero_normal_exit(self):
        text = 'finch-init: com.apple.notifyd: exited with status 1\r\n'
        self.assertEqual(
            runner.notifyd_exit_messages(text),
            ['finch-init: com.apple.notifyd: exited with status 1'])

    def test_each_logged_signal_is_unexpected_including_sigkill(self):
        text = ('finch-init: com.apple.notifyd: killed by signal 9\n'
                'finch-init: com.apple.notifyd: killed by signal 6\n')
        self.assertEqual(
            runner.notifyd_exit_messages(text),
            ['finch-init: com.apple.notifyd: killed by signal 9',
             'finch-init: com.apple.notifyd: killed by signal 6'])

    def test_ignores_clean_exit_and_other_jobs(self):
        text = ('finch-init: com.apple.notifyd: exited with status 0\n'
                'finch-init: org.finch.test.keepalive: exited with status 1\n')
        self.assertEqual(runner.notifyd_exit_messages(text), [])


if __name__ == '__main__':
    unittest.main()
