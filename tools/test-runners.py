#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Check that failed builds and tests cannot be mistaken for passing runs.

Uses disposable fake programs and a fake VM console. Does not boot a VM,
compile Finch, or touch the real staging tree.
"""
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def run(command, expected):
    result = subprocess.run(command, capture_output=True, text=True, timeout=15)
    if result.returncode != expected:
        raise AssertionError(f'{command}: wanted {expected}, got {result.returncode}\n'
                             f'{result.stdout}\n{result.stderr}')


def executable(path, text):
    path.write_text(text)
    path.chmod(0o755)


def host_runner(root):
    shutil.copy(ROOT / 'tools/host-tests.sh', root / 'tools/host-tests.sh')
    binary = root / 'build/userland/finch-cf-test'
    for status in (0, 7):
        executable(binary, f'#!/bin/bash\necho image\necho same-output\nexit {status}\n')
        run([str(root / 'tools/host-tests.sh'), 'cf-test'], 0 if status == 0 else 1)
    run([str(root / 'tools/host-tests.sh'), 'misspelled-test'], 1)
    binary.unlink()
    run([str(root / 'tools/host-tests.sh'), 'cf-test'], 1)
    print('host runner: failures, unknown names and missing selected tests rejected')


def build_runner(root):
    shutil.copy(ROOT / 'tools/build-system.sh', root / 'tools/build-system.sh')
    for project, status, failed, expected in (
        ('cron', 0, '', 0), ('cron', 1, '', 1), ('file_cmds', 1, '', 1),
        ('file_cmds', 1, 'deferred', 0), ('file_cmds', 1, 'unknown', 1)
    ):
        (root / f'build/logs/{project}.log').write_text('')
        (root / f'userland/oss/{project}.deferred').write_text('deferred\n')
        text = f'#!/bin/bash\necho "{project}: 1 Mach-O installed into build/root (build exit {status})"\n'
        if failed:
            text += f'echo "  failed in: {failed}  (see log)"\n'
        executable(root / 'tools/build-oss.sh', text)
        run([str(root / 'tools/build-system.sh'), project], expected)
    run([str(root / 'tools/build-system.sh'), 'misspelled-step'], 1)
    executable(root / 'tools/build-oss.sh', '#!/bin/bash\necho "$1: 1 Mach-O installed into build/root (build exit 0)"\necho "$1" >> build/steps-ran\n')
    run([str(root / 'tools/build-system.sh'), 'cron', 'file_cmds'], 0)
    assert (root / 'build/steps-ran').read_text().splitlines() == ['file_cmds', 'cron']
    print('build runner: failures and unknown names rejected; selected steps run in order')


def vm_runner(root):
    shutil.copy(ROOT / 'tools/vm/smoke.exp', root / 'tools/vm/smoke.exp')
    executable(root / 'tools/vm/run.sh', '''#!/usr/bin/env python3
import os, re, sys, tty
tty.setraw(0)
def out(text): os.write(1, text.encode())
out('# \\x1b[K\\x1b[?2004h')
line = ''
status = 0
while True:
    char = os.read(0, 1)
    if not char or char == b'\\x01': break
    if char in (b'\\r', b'\\n'):
        if line.startswith('finch_test_status='):
            marker = re.search(r'FINCH_TEST_RESULT_\\d+=', line).group()
            out('\\r\\n' + marker + str(status) + '\\r\\n# \\x1b[K\\x1b[?2004h')
        elif line == 'early-exit': sys.exit(0)
        else:
            status = 1 if line == 'false' else 0
            if line == 'loader-error': out('\\r\\ndyld: missing library\\r\\n')
            out('\\r\\n# \\x1b[K\\x1b[?2004h')
        line = ''
    else:
        line += char.decode()
''')
    for command, expected in (('true', 0), ('false', 4), ('early-exit', 1), ('loader-error', 3)):
        run(['expect', str(root / 'tools/vm/smoke.exp'), command], expected)
    print('VM runner: failed commands, early exit and loader errors rejected')


def main():
    with tempfile.TemporaryDirectory(prefix='finch-runner-tests-') as directory:
        root = Path(directory)
        for path in ('tools/vm', 'build/userland', 'build/logs', 'userland/oss'):
            (root / path).mkdir(parents=True, exist_ok=True)
        host_runner(root)
        build_runner(root)
        vm_runner(root)
    print('runner checks: PASS')


if __name__ == '__main__':
    main()
