#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Run Finch's test programs in the VM, in one boot, and check each one.

  tools/vm/vm-tests.py [NAME...]        (NAME as in finch-NAME; default: every test in the image)
  tools/vm/vm-tests.py --scripts        also run the VM test scripts that set up their own guest
  tools/vm/vm-tests.py --list           print each test and how it is checked, and stop
  tools/vm/vm-tests.py --coverage       list tests the Makefile builds that no suite runs

Build the image first (tools/vm/mkramdisk.sh). Each test program the image holds
(tools/vm/overlay.txt) is checked one of three ways:

  compare   the host suite's comparison tests (tools/host-tests.sh): the program is run on
            the host against Apple's frameworks, and the VM's output (all but the first line,
            which names the image used) must have the same checksum;
  expected  the host suite's window-server and Finch-only tests, and the overrides below:
            the VM's output must match the .expected file;
  exit      everything else: the program must exit 0 (these tests check themselves).

Every check also needs exit status 0: a failed program fails even if its output matches.
Known failures are listed, each with its reason, in tools/vm/vm-test-exceptions.txt; one
that passes again fails the run until its entry is removed. Prints one line per test and
a summary, and exits non-zero on any unexpected result.

Apple's frameworks are only run on the host, with no DYLD_* variables, so running this
from Python (which SIP strips them from) is fine.
"""
import re
import shlex
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
B = 'build/userland'
SERVER = '/usr/libexec/finch-windowserver'
# smoke.exp's message for a VM that died while booting (QEMU's intermittent SIGHUP): tried again once
BOOT_FAILED = '### VM exited before the shell started'
# Each test's time in the guest, below smoke.exp's 300 s for a command: a test that hangs is
# killed (exit 137) and the rest still run.
LIMIT = 240
EXCEPTIONS = ROOT / 'tools/vm/vm-test-exceptions.txt'
# A failed test's output from the VM (NAME.vm, NAME.err) and what it should be (NAME.want)
OUTPUTS = ROOT / 'build/vm-tests'

# VM-only tests that need arguments or an expected file (name -> (check, args, expected))
OVERRIDES = {
    'cg-draw-test': ('exit', 'userland/tests/cg-draw-reference.bin', None),
    'ctfonts-test': ('expected', '', 'userland/tests/ctfonts-expected.txt'),
    'pam-test': ('exit', 'login', None),
    # (the client: finch-init starts the job, org.finch.test.socket, on demand)
    'socket-test': ('exit', 'connect /var/run/org.finch.test.socket', None),
    # (they draw into PNGs: a file, or a folder of them)
    'appkit-controls2-render-test': ('exit', '/tmp/vmt-controls2.png', None),
    'appkit-containers2-render-test': ('exit', '/tmp/vmt-render', None),
    'appkit-color-browser-render-test': ('exit', '/tmp/vmt-render', None),
}
# Fields that depend on the machine, not on whose frameworks run (tools/test-masks.txt)
MASK_FILE = ROOT / 'tools/test-masks.txt'
# Arguments added to both runs: user defaults (the argument domain) in place of this Mac's
# own preferences, which the guest doesn't have
EXTRA_ARGS = {
    # this Mac may turn these off for everyone (defaults read -g); the guest has them on
    'textview-more-test': '-NSAutomaticQuoteSubstitutionEnabled YES -NSAutomaticDashSubstitutionEnabled YES '
                          '-NSAutomaticSpellingCorrectionEnabled YES',
}
# Settings the host suite runs Finch with (tools/host-tests.sh), for the guest too
GUEST_ENV = 'export FINCH_THEME=Classic FINCH_TEST_TICK=1'  # (window tests' steps a second apart: QEMU is slow)
# Host paths in arguments that the image doesn't hold, and where the guest uses instead
# (made before the test runs)
VM_DIRS = {
    'build/coreservices-test': '/tmp/finch-coreservices-test',
}
# Folders a test writes into, made before it runs
SETUP = {
    'appkit-containers2-render-test': '/tmp/vmt-render',
    'appkit-color-browser-render-test': '/tmp/vmt-render',
}
# Tests that need a guest set up first: their own scripts run them (with --scripts).
SCRIPTS = {
    'tools/vm/test-accounts.sh': ['account-login-test', 'account-tools-test'],
    'tools/vm/test-settings.sh': ['configd-service-test', 'configd-network-test'],
    'tools/vm/test-keychain.sh': ['security-keychain-service-test', 'security-keychain-storage-test',
                                  'security-keychain-encryption-test', 'keychain-crypto-test'],
    'tools/vm/test-drag.sh': ['appkit-drag-apps-test'],
}
# Not test programs, or run by another test.
NOT_TESTS = {'app-test'}


def overlay():
    """Source path -> path in the image."""
    paths = {}
    for line in (ROOT / 'tools/vm/overlay.txt').read_text().splitlines():
        parts = line.split('#', 1)[0].split()
        if len(parts) == 2:
            paths.setdefault(parts[0], parts[1])  # (a file installed twice: its first place)
    return paths


def host_suite():
    """The host suite's lists: (comparison tests, window-server tests, Finch-only tests)."""
    text = (ROOT / 'tools/host-tests.sh').read_text()

    def array(name):
        m = re.search(r'^%s=\((.*?)\)$' % name, text, re.S | re.M)
        return re.findall(r'"([^"]*)"', m.group(1)) if m else []

    def entries(name):
        out = {}
        for entry in array(name):
            test, _, args = entry.partition('|')
            out[test] = args.replace('${B}', B)
        return out

    expect = {}
    m = re.search(r'^EXPECT=\(([^)]*)\)', text, re.M)
    for name in m.group(1).split():
        expect['appkit-%s-test' % name] = 'userland/tests/appkit-%s-test.expected' % name
    return entries('COMPARE'), expect, entries('FINCH_ONLY')


def vm_args(args, paths):
    """Host paths in a test's arguments, as the image has them."""
    out = []
    for arg in shlex.split(args):
        if arg in VM_DIRS:
            out.append(VM_DIRS[arg])
        elif arg in paths:
            out.append(paths[arg])
        elif arg == B:
            out.append('/usr/local/share/finch')
        else:
            out.append(arg)
    return ' '.join(shlex.quote(a) for a in out)


def masks():
    """test -> [(pattern, replacement)], from tools/test-masks.txt's sed substitutions."""
    out = {}
    for line in MASK_FILE.read_text().splitlines():
        if not line.strip() or line.startswith('#'):
            continue
        name, sub = line.split(None, 1)
        _, pattern, replacement, _ = sub.split('#')
        out.setdefault(name, []).append((pattern, replacement))
    return out


MASKS = masks()


def mask(name, data):
    text = data.decode('utf-8', 'surrogateescape')
    for pattern, replacement in MASKS.get(name, []):
        text = re.sub(pattern, replacement, text, flags=re.M)
    return text.encode('utf-8', 'surrogateescape')


def cksum(data):
    return subprocess.run(['cksum'], input=data, capture_output=True, check=True).stdout.decode().strip()


def plan(selected):
    paths = overlay()
    compare, expect, finch_only = host_suite()
    in_scripts = {t for tests in SCRIPTS.values() for t in tests}
    tests = []
    for src, dst in paths.items():
        m = re.fullmatch(r'build/userland/finch-(.+-test)', src)
        if not m or m.group(1) in NOT_TESTS or m.group(1) in in_scripts:
            continue
        name = m.group(1)
        if selected and name not in selected:
            continue
        if name in compare:
            tests.append((name, 'compare', compare[name], None))
        elif name in expect:
            tests.append((name, 'expected', SERVER, expect[name]))
        elif name in finch_only:
            tests.append((name, 'expected', finch_only[name], 'userland/tests/%s.expected' % name))
        elif name in OVERRIDES:
            check, args, expected = OVERRIDES[name]
            tests.append((name, check, args, expected))
        else:
            tests.append((name, 'exit', '', None))
    tests = [(n, c, (a + ' ' + EXTRA_ARGS[n]).strip() if n in EXTRA_ARGS else a, e) for n, c, a, e in tests]
    return tests, paths


def coverage():
    """Tests userland/tests/Makefile builds that neither suite nor a VM script runs."""
    built = set(re.findall(r'\$\(OUT\)/finch-([a-z0-9-]+-test)\b', (ROOT / 'userland/tests/Makefile').read_text()))
    compare, expect, finch_only = host_suite()
    host = set(compare) | set(expect) | set(finch_only)
    # (the host suite also runs these through other programs: tools/host-tests.sh's last checks)
    host |= {'contacts-test', 'metal-test', 'app-test'}
    in_vm = {m.group(1) for src in overlay() for m in [re.fullmatch(r'build/userland/finch-(.+-test)', src)] if m}
    scripted = {t for tests in SCRIPTS.values() for t in tests}
    return sorted(built - host - in_vm - scripted)


def main_display_1x():
    """Is this Mac's main display not Retina? (Apple's references then round to whole points.)"""
    out = subprocess.run(['system_profiler', 'SPDisplaysDataType'], capture_output=True, text=True).stdout
    resolution = ''
    for line in out.splitlines():
        if 'Resolution:' in line:
            resolution = line
        elif 'Main Display: Yes' in line:
            return 'Retina' not in resolution
    return False


def exceptions():
    known = {}
    # the host suite's display exceptions hold here too: the references are its Apple runs
    if main_display_1x():
        for line in (ROOT / 'tools/host-test-exceptions.txt').read_text().splitlines():
            m = re.match(r'([a-z0-9-]+) \(1x display\):\s*(.*)', line)
            if m:
                known[m.group(1)] = '1x main display: ' + m.group(2)
    if EXCEPTIONS.exists():
        for line in EXCEPTIONS.read_text().splitlines():
            line = line.split('#', 1)[0].strip()
            if line:
                name, _, reason = line.partition(':')
                known[name.strip()] = reason.strip()
    return known


def main():
    argv = sys.argv[1:]
    scripts = '--scripts' in argv
    listing = '--list' in argv
    if '--coverage' in argv:
        missing = coverage()
        for name in missing:
            print('%-36s built, but no suite runs it' % name)
        print('%d tests run by no suite' % len(missing))
        return 1 if missing else 0
    selected = {a for a in argv if not a.startswith('--')}
    tests, paths = plan(selected)
    if selected - {t[0] for t in tests}:
        sys.exit('unknown or script-run test: %s' % ' '.join(sorted(selected - {t[0] for t in tests})))
    if listing:
        for name, check, args, expected in tests:
            print('%-36s %-8s %s%s' % (name, check, vm_args(args, paths), ' -> ' + expected if expected else ''))
        for script, names in SCRIPTS.items():
            print('%-36s %-8s %s' % (', '.join(names), 'script', script))
        return 0

    # what each test's output must be: Apple's on the host, or the expected file
    want, wanted = {}, {}
    for name, check, args, expected in tests:
        if check == 'compare':
            run = subprocess.run([str(ROOT / B / ('finch-' + name))] + shlex.split(args), cwd=ROOT,
                                 capture_output=True)
            lines = run.stdout.split(b'\n', 1)
            if run.returncode != 0 or len(lines) < 2:
                want[name] = None  # Apple's run failed: reported below
            else:
                wanted[name] = mask(name, lines[1])
                want[name] = cksum(wanted[name])
        elif check == 'expected':
            wanted[name] = mask(name, (ROOT / expected).read_bytes())
            want[name] = cksum(wanted[name])

    commands = []
    for name, check, args, expected in tests:
        out = '/tmp/vmt.out'
        body = 'tail -n +2 %s' % out if check == 'compare' else 'cat %s' % out
        for pattern, replacement in MASKS.get(name, []):
            body += " | sed -E %s" % shlex.quote('s#%s#%s#' % (pattern, replacement))
        made = [VM_DIRS[a] for a in shlex.split(args) if a in VM_DIRS] + ([SETUP[name]] if name in SETUP else [])
        cmd = ''.join('mkdir -p %s; ' % shlex.quote(d) for d in made)
        cmd += ('finch-%s %s > %s 2> /tmp/vmt.err & p=$!; (sleep %d; kill -9 $p) 2> /dev/null & w=$!; '
               'wait $p; s=$?; kill $w 2> /dev/null; c=$(%s | cksum); echo "VMT|%s|$s|$c"; '
               % (name, vm_args(args, paths), out, LIMIT, body, name))
        bad = '[ $s -ne 0 ]' if check == 'exit' else '[ $s -ne 0 ] || [ "$c" != "%s" ]' % (want.get(name) or '-')
        cmd += ('if %s; then %s | head -n 2000 | sed "s/^/VMOUT|%s|/"; tail -n 40 /tmp/vmt.err | sed "s/^/VMERR|%s|/"; fi; true'
                % (bad, body, name, name))
        commands.append(cmd)

    commands.insert(0, GUEST_ENV)
    log = tempfile.NamedTemporaryFile(prefix='vm-tests.', suffix='.log', delete=False)
    print('VM log: %s' % log.name, flush=True)
    for attempt in range(2):
        log.seek(0)
        log.truncate()
        status = subprocess.run([str(ROOT / 'tools/vm/with-vm-lock.sh'), 'expect', str(ROOT / 'tools/vm/smoke.exp')] + commands,
                                cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL).returncode
        log.flush()
        text = Path(log.name).read_text(errors='replace')
        if BOOT_FAILED not in text:
            break
        print('the VM stopped before its shell started; booting it again', flush=True)
    text = re.sub(r'\x1b\[[0-9;?]*[A-Za-z]', '', text)
    results = {}
    for m in re.finditer(r'^VMT\|([^|\s]+)\|(\d+)\|(\d+ \d+)\s*$', text, re.M):
        results[m.group(1)] = (int(m.group(2)), m.group(3))

    OUTPUTS.mkdir(parents=True, exist_ok=True)
    for name, check, args, expected in tests:
        for kind in ('OUT', 'ERR'):
            lines = re.findall(r'^VM%s\|%s\|(.*?)\r?$' % (kind, re.escape(name)), text, re.M)
            if lines:
                (OUTPUTS / ('%s.%s' % (name, 'vm' if kind == 'OUT' else 'err'))).write_text('\n'.join(lines) + '\n')
                if name in wanted:
                    (OUTPUTS / ('%s.want' % name)).write_bytes(wanted[name])

    known = exceptions()
    passed = failed = expected_fail = 0
    for name, check, args, expected in tests:
        if name not in results:
            verdict, ok = 'no result (see the VM log)', False
        else:
            code, got = results[name]
            if code == 137:
                verdict, ok = 'FAILED (killed after %d s, or exit 137)' % LIMIT, False
            elif code != 0:
                verdict, ok = 'FAILED (exit %d)' % code, False
            elif check == 'compare' and want.get(name) is None:
                verdict, ok = "no output from Apple's run", False
            elif check != 'exit' and got != want[name]:
                verdict, ok = 'DIFFERS from %s' % ("Apple's" if check == 'compare' else 'expected'), False
            else:
                verdict, ok = 'ok (%s)' % check, True
        if name in known:
            if ok:
                verdict = 'passes now: remove its exception'
                failed += 1
            else:
                verdict = 'known: %s (%s)' % (verdict, known[name])
                expected_fail += 1
        elif ok:
            passed += 1
        else:
            failed += 1
        print('%-36s %s' % (name, verdict))
    for name in known:
        if name not in {t[0] for t in tests} and not selected:
            print('%-36s %s' % (name, 'exception for a test not in the image: remove it'))
            failed += 1
    if status not in (0, 4):
        print('### the VM run itself failed (smoke.exp exit %d)' % status)
        failed += 1

    if scripts and not selected:
        for script in SCRIPTS:
            for attempt in range(2):
                run = subprocess.run([str(ROOT / script)], cwd=ROOT, capture_output=True, text=True,
                                     stdin=subprocess.DEVNULL)
                if BOOT_FAILED not in run.stdout:
                    break
            name = ', '.join(SCRIPTS[script])
            if run.returncode == 0:
                print('%-36s ok (%s)' % (name, script))
                passed += 1
            else:
                print('%-36s FAILED (%s exit %d)' % (name, script, run.returncode))
                sys.stdout.write(run.stdout[-2000:])
                failed += 1

    print('%d passed, %d failed, %d known failures' % (passed, failed, expected_fail))
    if failed:
        print('failed tests\' output: %s (diff NAME.want NAME.vm)' % OUTPUTS.relative_to(ROOT))
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
