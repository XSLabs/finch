#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Check the built app runner's exit handling on its own headless server.

Uses only true/false and a window name that cannot exist; no user app is opened.
Build finch-app-test and finch-windowserver first. The host must allow shared memory.
"""
import os
from pathlib import Path
import signal
import subprocess


ROOT = Path(__file__).resolve().parents[1]
LIBRARY = ROOT / 'build/root/System/Library'


def main():
    env = os.environ.copy()
    env.pop('FINCH_SHELL', None)
    env.pop('FINCH_APP_ARGS', None)
    frameworks = [LIBRARY / 'Frameworks', LIBRARY / 'PrivateFrameworks',
                  LIBRARY / 'Frameworks/Quartz.framework/Frameworks']
    for umbrella in ('CoreServices', 'ApplicationServices', 'Carbon'):
        frameworks.append(LIBRARY / f'Frameworks/{umbrella}.framework/Versions/A/Frameworks')
    env['DYLD_FRAMEWORK_PATH'] = ':'.join(map(str, frameworks))
    env['DYLD_LIBRARY_PATH'] = str(ROOT / 'build/root/usr/lib/swift')
    env['FINCH_FONT_DIRS'] = str(LIBRARY / 'Fonts')
    runner = ROOT / 'build/userland/finch-app-test'
    server = ROOT / 'build/root/usr/libexec/finch-windowserver'
    cases = [('clean exit', '/usr/bin/true', ['wait:100'], 0, None),
             ('failed app', '/usr/bin/false', ['wait:100'], 1, 'app failed'),
             ('unknown step', '/usr/bin/true', ['not-a-real-step'], 1, 'unknown step'),
             ('missing window', '/usr/bin/true', ['window:Finch-Test-Window-That-Does-Not-Exist'],
              1, 'not found')]
    for name, app, steps, status, marker in cases:
        process = subprocess.Popen([str(runner), str(server), app, *steps], env=env,
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                   text=True, start_new_session=True)
        try:
            output, _ = process.communicate(timeout=30)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.communicate()
            raise SystemExit(f'{name}: app runner did not finish')
        if process.returncode != status or (marker and marker not in output):
            raise SystemExit(f'{name}: expected exit {status}, got {process.returncode}\n{output}')
        print(f'{name}: passed')


if __name__ == '__main__':
    main()
