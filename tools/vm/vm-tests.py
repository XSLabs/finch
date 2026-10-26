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
  exit      explicitly listed checks that assert their own results or check for crashes.

New tests need an explicit check; merely printing results and exiting 0 is not a pass.

Every check also needs exit status 0: a failed program fails even if its output matches.
Known failures are listed, each with its reason, in tools/vm/vm-test-exceptions.txt; one
that passes again fails the run until its entry is removed. Prints one line per test and
a summary, and exits non-zero on any unexpected result.

Apple's frameworks are only run on the host, with no DYLD_* variables, so running this
from Python (which SIP strips them from) is fine.
"""
import argparse
import contextlib
import datetime
import hashlib
import json
import os
import re
import shlex
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools'))
from video_comparison import matches as video_matches
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
VM_INPUTS = ('KC', 'RAMDISK', 'TC')

# VM-only tests that need arguments or an expected file (name -> (check, args, expected))
OVERRIDES = {
    'ws-test': ('expected', SERVER, 'userland/tests/ws-test.expected'),
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
# These programs return failure when their own checks fail. Do not add a program
# that merely prints results here: give it a comparison or expected output instead.
EXIT_CHECKS = {
    'libsystem-test', 'xpc-service-test', 'cxx-test', 'objc-test', 'crypto-test',
    'sysconfig-core-test', 'appkit-gestures-test', 'compression-test',
    'font-replacements-test', 'log-test', 'introspect-test', 'mdnsd-test',
    'diskarbitration-session-test',
    'sandbox-enforcement-proof-test',
    'sandbox-profile-test',
    'sandbox-request-test', 'notify-access-test', 'notify-path-access-test',
    'notify-restart-test',
    'notify-path-lifecycle-test',
    'notify-path-direct-test',
    'notify-path-cancel-test',
    'notify-path-permission-test',
    'bootstrap-failure-test',
    # This is only a crash check for a process with hardened-process entitlements.
    'hardened-test',
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
    'cf-preferences-container-test': '/tmp/finch-vmt-prefs',
    'appkit-containers2-render-test': '/tmp/vmt-render',
    'appkit-color-browser-render-test': '/tmp/vmt-render',
}
# Tests that need a guest set up first: their own scripts run them (with --scripts).
SCRIPTS = {
    'tools/vm/test-bootstrap-startup-failure.sh': [],
    'tools/vm/test-coredata.py': ['coredata-test'],
    'tools/vm/test-accounts.sh': ['account-login-test', 'account-tools-test'],
    'tools/vm/test-settings.sh': ['configd-service-test', 'configd-network-test'],
    'tools/vm/test-keychain.sh': ['security-keychain-service-test', 'security-keychain-storage-test',
                                  'security-keychain-encryption-test', 'keychain-crypto-test'],
    'tools/vm/test-drag.sh': ['appkit-drag-apps-test'],
    'tools/vm/test-services.sh': [],  # (the daemons running, and cron running a job)
    'tools/vm/test-login.sh': ['security-keychain-login-test'],
    'tools/vm/test-authorization.sh': ['authorization-test'],
    'tools/vm/test-chpass.sh': ['chpass-test'],
    'tools/vm/test-app-sandbox.sh': ['app-sandbox-test'],
    'tools/vm/test-trust-settings.sh': [],
    'tools/vm/test-disks.sh': [],
}
# test-keychain.sh builds these images itself, then login-init-smoke.exp overrides the
# inherited RAMDISK and TC with them. The script prints a VMTIMAGE record for each just before
# launching the guest; the runner checks those hashes again when the script exits.
SCRIPT_IMAGE_OVERRIDES = {
    'tools/vm/test-keychain.sh': {
        'RAMDISK': ROOT / 'build/vm-login-test/ramdisk.dmg',
        'TC': ROOT / 'build/vm-login-test/ramdisk.tc',
    },
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
            out[test] = args.replace('${B}', B).replace('${SERVER}', 'build/root/usr/libexec/finch-windowserver')
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


def reference_output(name, args):
    """A stalled or empty Apple run cannot become a passing reference."""
    try:
        env = {key: value for key, value in os.environ.items()
               if not key.startswith(('DYLD_', 'FINCH_')) and key != 'CFFIXED_USER_HOME'}
        with contextlib.ExitStack() as cleanup:
            if name == 'cf-preferences-container-test':
                env['CFFIXED_USER_HOME'] = cleanup.enter_context(tempfile.TemporaryDirectory(prefix='finch-vmt-prefs-'))
            run = subprocess.run([str(ROOT / B / ('finch-' + name))] + shlex.split(args),
                                 cwd=ROOT, capture_output=True, timeout=LIMIT, env=env)
    except subprocess.TimeoutExpired:
        return None, "Apple's run exceeded %d seconds" % LIMIT
    except OSError as error:
        return None, "could not start Apple's run: %s" % error
    if run.returncode != 0:
        return None, "Apple's run failed (exit %d)" % run.returncode
    lines = run.stdout.split(b'\n', 1)
    if len(lines) < 2 or not lines[1].strip():
        return None, "no comparison output from Apple's run"
    return mask(name, lines[1]), None


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
        elif name in OVERRIDES:
            check, args, expected = OVERRIDES[name]
            tests.append((name, check, args, expected))
        elif name in finch_only:
            tests.append((name, 'expected', finch_only[name], 'userland/tests/%s.expected' % name))
        elif name in EXIT_CHECKS:
            tests.append((name, 'exit', '', None))
        else:
            raise ValueError('no result check for %s; choose comparison, expected output, or an explicit self-check' % name)
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


def resolve_vm_inputs(environ=None):
    """Resolve the exact files run.sh will pass to QEMU, and reject missing files."""
    environ = os.environ if environ is None else environ
    firmware = ROOT / 'third_party/darwin-vm/firmware'
    built_ramdisk = ROOT / 'build/vm/ramdisk.dmg'
    use_built_ramdisk = built_ramdisk.is_file()
    defaults = {
        'KC': firmware / 'bootkc',
        'RAMDISK': built_ramdisk if use_built_ramdisk else firmware / 'ramdisk.dmg',
        'TC': ROOT / 'build/vm/ramdisk.tc' if use_built_ramdisk else firmware / 'ramdisk.tc',
    }
    paths = {}
    for name in VM_INPUTS:
        value = environ.get(name) or str(defaults[name])
        path = Path(value)
        if not path.is_absolute():
            # run.sh is called with cwd=ROOT, so relative overrides are rooted there too.
            path = ROOT / path
        try:
            path = path.resolve(strict=True)
        except OSError as error:
            raise ValueError('%s input is missing: %s (%s)' % (name, path, error)) from error
        if not path.is_file():
            raise ValueError('%s input is not a regular file: %s' % (name, path))
        paths[name] = path
    return paths


def vm_environment(inputs, environ=None):
    """Pass the resolved image files to run.sh and any VM test scripts."""
    result = dict(os.environ if environ is None else environ)
    result.update({name: str(path) for name, path in inputs.items()})
    return result


def vm_boot_options(environ=None):
    """Record only the boot settings that can change how the guest starts."""
    environ = os.environ if environ is None else environ
    built_ramdisk = (ROOT / 'build/vm/ramdisk.dmg').is_file()

    init_setting = environ.get('FINCH_INIT') or None
    if init_setting is None:
        init_value = '1' if built_ramdisk else '0'
        init_source = ('run.sh default (built Finch ramdisk exists)' if built_ramdisk
                       else 'run.sh default (no built Finch ramdisk)')
    else:
        init_value = init_setting
        init_source = 'environment'
    init_enabled = init_value == '1'

    console_setting = environ.get('FINCH_DEV_CONSOLE') or None
    console_value = console_setting or '1'
    console_source = 'environment' if console_setting is not None else 'run.sh default (1)'

    extra_setting = environ.get('BOOT_ARGS_EXTRA') or None
    extra_value = extra_setting or ''
    extra_source = 'environment' if extra_setting is not None else 'run.sh default (empty)'

    return {
        'FINCH_INIT': {'value': init_value, 'source': init_source, 'enabled': init_enabled},
        'FINCH_DEV_CONSOLE': {
            'value': console_value,
            'source': console_source,
            'used': init_enabled,
            'enabled': init_enabled and console_value == '1',
        },
        'BOOT_ARGS_EXTRA': {'value': extra_value, 'source': extra_source},
    }


def vm_input_hashes(inputs):
    """Hash host files in chunks so large disk images do not fill memory."""
    hashes = {}
    for name, path in inputs.items():
        digest = hashlib.sha256()
        try:
            with path.open('rb') as image:
                for block in iter(lambda: image.read(1024 * 1024), b''):
                    digest.update(block)
        except OSError as error:
            raise ValueError('cannot read %s input %s: %s' % (name, path, error)) from error
        hashes[name] = digest.hexdigest()
    return hashes


def vm_input_record(inputs, hashes):
    return [
        {'name': name, 'path': str(inputs[name]), 'sha256': hashes[name]}
        for name in VM_INPUTS
    ]


def parse_script_image_markers(text, expected_images):
    """Read strict launch-time image records from a VM script's output."""
    expected_paths = {name: str(Path(path).resolve()) for name, path in expected_images.items()}
    records = {}
    seen = set()
    invalid = set()
    errors = []

    for line_number, line in enumerate((text or '').splitlines(), 1):
        stripped = line.lstrip()
        if not stripped.startswith('VMTIMAGE'):
            continue
        if line != stripped:
            fields = stripped.split('|')
            name = fields[1] if len(fields) > 1 else None
            if name in expected_paths:
                seen.add(name)
                invalid.add(name)
                records.pop(name, None)
            errors.append('line %d: malformed VMTIMAGE record' % line_number)
            continue
        fields = line.split('|')
        if len(fields) != 4 or fields[0] != 'VMTIMAGE':
            name = fields[1] if len(fields) > 1 else None
            if name in expected_paths:
                if name in seen:
                    errors.append('line %d: duplicate VMTIMAGE record for %s' % (line_number, name))
                seen.add(name)
                invalid.add(name)
                records.pop(name, None)
            errors.append('line %d: malformed VMTIMAGE record' % line_number)
            continue

        _, name, path, digest = fields
        if name in seen:
            errors.append('line %d: duplicate VMTIMAGE record for %s' % (line_number, name))
            invalid.add(name)
            records.pop(name, None)
            continue
        seen.add(name)
        if name not in expected_paths:
            errors.append('line %d: unexpected VMTIMAGE name %r' % (line_number, name))
            continue
        if path != expected_paths[name]:
            errors.append('line %d: VMTIMAGE path for %s does not match the expected image' % (
                line_number, name))
            invalid.add(name)
            continue
        if not re.fullmatch(r'[0-9a-f]{64}', digest):
            errors.append('line %d: VMTIMAGE hash for %s is not a SHA-256 value' % (
                line_number, name))
            invalid.add(name)
            continue
        records[name] = {'path': path, 'sha256': digest}

    for name in expected_paths:
        if name not in seen:
            errors.append('missing VMTIMAGE record for %s' % name)
        elif name not in records and name not in invalid:
            errors.append('no valid VMTIMAGE record for %s' % name)
    return records, errors


def run_test_script(script, run_env, vm_inputs):
    """Run one VM script and verify its custom images at launch and after exit."""
    run = None
    for attempt in range(2):
        run = subprocess.run([str(ROOT / script)], cwd=ROOT, capture_output=True, text=True,
                             env=run_env, stdin=subprocess.DEVNULL)
        if BOOT_FAILED not in run.stdout:
            break

    record = {
        'script': script,
        'exitCode': run.returncode,
        'inheritedInputs': {name: str(vm_inputs[name]) for name in VM_INPUTS},
        'imageOverrides': {},
    }
    overrides = SCRIPT_IMAGE_OVERRIDES.get(script, {})
    launch_records, evidence_errors = parse_script_image_markers(run.stdout, overrides)
    record['imageEvidenceErrors'] = list(evidence_errors)
    try:
        hashes_after = vm_input_hashes(overrides)
    except ValueError as error:
        hashes_after = {}
        record['imageEvidenceErrors'].append(str(error))

    for name, path in overrides.items():
        expected_path = str(Path(path).resolve())
        launch = launch_records.get(name)
        item = {
            'path': expected_path,
            'capturePoint': 'VMTIMAGE marker immediately before guest launch',
            'verifiedAtLaunch': launch is not None,
        }
        if launch is not None:
            item['sha256AtLaunch'] = launch['sha256']
        if name in hashes_after:
            item['sha256AfterScript'] = hashes_after[name]
            if launch is not None:
                item['unchangedAfterScript'] = launch['sha256'] == hashes_after[name]
                if not item['unchangedAfterScript']:
                    record['imageEvidenceErrors'].append(
                        '%s image changed after guest launch' % name)
        else:
            item['captureError'] = 'could not hash image after script exit'
        if launch is None:
            item['verifiedAtLaunch'] = False
        record['imageOverrides'][name] = item
    record['imageEvidenceValid'] = not record['imageEvidenceErrors']
    return run, record


def write_run_record(path, record):
    path.write_text(json.dumps(record, indent=2, sort_keys=True) + '\n')


def _dimensions(value):
    match = re.search(r'(?<!\d)(\d+)\s*x\s*(\d+)(?!\d)', value)
    return [int(match.group(1)), int(match.group(2))] if match else None


def parse_display_snapshot(output):
    """Keep only display count, online/main state, and pixel-to-point scale details."""
    screens = []
    current = None

    def finish_screen():
        if current is None:
            return
        pixels = current['pixelResolution']
        points = current['uiResolution']
        if pixels and points and points[0] and points[1]:
            scale = [round(pixels[0] / points[0], 3), round(pixels[1] / points[1], 3)]
        elif current['retina']:
            scale = [2.0, 2.0]
        elif pixels:
            scale = [1.0, 1.0]
        else:
            scale = None
        current['scale'] = scale
        screens.append(current.copy())

    if output is not None:
        for line in output.splitlines():
            key, separator, value = line.strip().partition(':')
            if not separator:
                continue
            value = value.strip()
            if key == 'Resolution':
                finish_screen()
                current = {
                    'pixelResolution': _dimensions(value),
                    'uiResolution': None,
                    'retina': 'Retina' in value,
                    'main': None,
                    'online': None,
                }
            elif current is not None and key == 'UI Looks like':
                current['uiResolution'] = _dimensions(value)
            elif current is not None and key == 'Main Display':
                current['main'] = value == 'Yes'
            elif current is not None and key == 'Online':
                if value in ('Yes', 'No'):
                    current['online'] = value == 'Yes'
        finish_screen()

    online_known = any(screen['online'] is not None for screen in screens)
    online_count = sum(screen['online'] is True for screen in screens)

    def is_1x(screen):
        return screen['scale'] == [1.0, 1.0]

    online_screen_present = (True if online_count else
                             False if not screens or all(screen['online'] is not None for screen in screens)
                             else None)
    return {
        'sourceAvailable': output is not None,
        'screenCount': len(screens),
        'onlineScreenCount': online_count if online_known or not screens else None,
        'onlineScreenPresent': online_screen_present,
        'mainDisplay1x': any(screen['main'] is True and screen['online'] is True and is_1x(screen)
                             for screen in screens),
        'attached1x': any(screen['online'] is True and is_1x(screen) for screen in screens),
        'screens': screens,
    }


def display_1x_state(output):
    """Return whether the main screen, or any online screen, has 1x scaling."""
    snapshot = parse_display_snapshot(output)
    return snapshot['mainDisplay1x'], snapshot['attached1x']


def display_info():
    """Read only the screen details from system_profiler; never try to wake a display."""
    try:
        run = subprocess.run(['system_profiler', 'SPDisplaysDataType'], capture_output=True,
                             text=True, timeout=15)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return run.stdout if run.returncode == 0 else None


def capture_display_snapshot():
    snapshot = parse_display_snapshot(display_info())
    snapshot['capturedAt'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    snapshot['source'] = 'system_profiler SPDisplaysDataType'
    return snapshot


def display_context_signature(snapshot):
    """Normalize the small set of screen facts that can affect reference output."""
    if not snapshot or not snapshot.get('sourceAvailable'):
        return None
    screens = []
    for screen in snapshot['screens']:
        screens.append((tuple(screen['pixelResolution'] or ()), tuple(screen['uiResolution'] or ()),
                        tuple(screen['scale'] or ()), screen['retina'], screen['main'], screen['online']))
    return tuple(sorted(screens, key=repr))


def display_context_changed(before, after):
    before_signature = display_context_signature(before)
    after_signature = display_context_signature(after)
    if before_signature is None or after_signature is None:
        return None
    return before_signature != after_signature


def apple_reference_display_warnings(before, after, reference_count):
    """Describe display context limits without changing comparison results."""
    if not reference_count:
        return []
    warnings = []
    if not before.get('sourceAvailable') or not after.get('sourceAvailable'):
        warnings.append('Could not read screen state before or after Apple references; display-sensitive results are unconfirmed.')
    if before.get('onlineScreenPresent') is not True or after.get('onlineScreenPresent') is not True:
        warnings.append('No online screen was confirmed at one or both endpoints; display-sensitive results may not be comparable.')
    changed = display_context_changed(before, after)
    if changed is True:
        warnings.append('Screen context changed while preparing Apple references; display-sensitive results may mix conditions.')
    elif changed is None and before.get('sourceAvailable') and after.get('sourceAvailable'):
        warnings.append('Screen context could not be compared across Apple reference preparation.')
    return warnings


def exceptions(display_snapshot=None):
    known = {}
    # The Apple reference runs use this Mac too. A saved nib can land on an attached 1x
    # screen even when the main display is Retina, so match the host suite's rule.
    snapshot = display_snapshot if display_snapshot is not None else capture_display_snapshot()
    main_1x, attached_1x = snapshot['mainDisplay1x'], snapshot['attached1x']
    if main_1x or attached_1x:
        for line in (ROOT / 'tools/host-test-exceptions.txt').read_text().splitlines():
            m = re.match(r'([a-z0-9-]+) \(1x display\):\s*(.*)', line)
            if m:
                known[m.group(1)] = '1x display: ' + m.group(2)
    if EXCEPTIONS.exists():
        for line in EXCEPTIONS.read_text().splitlines():
            line = line.split('#', 1)[0].strip()
            if line:
                name, _, reason = line.partition(':')
                known[name.strip()] = reason.strip()
    return known


def borrowed_components(text):
    return set(re.findall(r'^VMTBORROWED\|([a-z0-9-]+)\r*$', text, re.M))


def notifyd_exit_messages(text):
    """Return logged crashes and nonzero exits of the supervised notifyd job."""
    # notify-restart-test stops notifyd with SIGKILL, but finch-init suppresses
    # SIGKILL and SIGTERM messages. Any notifyd exit that is logged is unexpected,
    # even when the restart test ran; do not excuse one based on test selection.
    pattern = (r'finch-init: com\.apple\.notifyd: '
               r'(?:killed by signal \d+|exited with status [1-9]\d*)')
    text = re.sub(r'\x1b\[[0-9;?]*[A-Za-z]', '', text)
    return re.findall(pattern, text)


def main():
    parser = argparse.ArgumentParser(description='Run and check Finch tests in the VM.')
    parser.add_argument('--scripts', action='store_true', help='also run separate VM test scripts')
    parser.add_argument('--list', action='store_true', help='list tests without running them')
    parser.add_argument('--coverage', action='store_true', help='check that every built test has a runner')
    parser.add_argument('tests', nargs='*', metavar='NAME')
    options = parser.parse_args()
    scripts = options.scripts
    listing = options.list
    if options.coverage:
        missing = coverage()
        for name in missing:
            print('%-36s built, but no suite runs it' % name)
        print('%d tests run by no suite' % len(missing))
        return 1 if missing else 0
    selected = set(options.tests)
    tests, paths = plan(selected)
    if selected - {t[0] for t in tests}:
        sys.exit('unknown or script-run test: %s' % ' '.join(sorted(selected - {t[0] for t in tests})))
    if listing:
        for name, check, args, expected in tests:
            print('%-36s %-8s %s%s' % (name, check, vm_args(args, paths), ' -> ' + expected if expected else ''))
        for script, names in SCRIPTS.items():
            print('%-36s %-8s %s' % (', '.join(names), 'script', script))
        return 0

    # Capture the image identities before the Apple references or other test preparation run.
    # This lets the saved record describe all work done for this test run.
    try:
        vm_inputs = resolve_vm_inputs()
        hashes_before = vm_input_hashes(vm_inputs)
    except ValueError as error:
        print('Cannot start VM tests: %s' % error, file=sys.stderr)
        return 1
    run_env = vm_environment(vm_inputs)
    OUTPUTS.mkdir(parents=True, exist_ok=True)
    log = tempfile.NamedTemporaryFile(prefix='vm-tests.', suffix='.log', delete=False)
    display_before = capture_display_snapshot()
    reference_count = sum(check == 'compare' for _, check, _, _ in tests)
    scripts_requested = scripts and not selected
    script_plan = []
    if scripts_requested:
        for script in SCRIPTS:
            script_plan.append({
                'script': script,
                'inheritedInputs': {name: str(vm_inputs[name]) for name in VM_INPUTS},
                'knownImageOverrides': {
                    name: {
                        'path': str(path),
                        'hashCapture': 'VMTIMAGE marker before guest launch plus post-script rehash',
                        'launchTimeHashRequired': True,
                    }
                    for name, path in SCRIPT_IMAGE_OVERRIDES.get(script, {}).items()
                },
            })
    record_path = OUTPUTS / 'run.json'
    run_record = {
        'startedAt': datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'log': log.name,
        'tests': [{'name': name, 'check': check} for name, check, _, _ in tests],
        'scriptsRequested': scripts_requested,
        'scriptPlan': script_plan,
        'unexpectedServiceExits': [],
        # Guest marker declarations only; this is not a full component audit.
        'mainGuestDeclaredBorrowedComponents': None,
        'inputsBefore': vm_input_record(vm_inputs, hashes_before),
        'inputsAfter': None,
        'inputsUnchanged': None,
        'bootOptions': vm_boot_options(run_env),
        'appleReferenceDisplay': {
            'before': display_before,
            'after': None,
            'contextChanged': None,
            'warnings': [],
            'limitations': ([
                'The before and after snapshots show only the endpoints; temporary screen changes between them may not be detected.'
            ] if reference_count else []),
        },
        'scope': ('The input hashes identify host KC, RAMDISK, and TC files. Scripts inherit '
                  'those paths, but may intentionally override them. These hashes do not prove '
                  'guest enforcement.'),
    }
    try:
        write_run_record(record_path, run_record)
    except OSError as error:
        log.close()
        print('Cannot save VM run record: %s' % error, file=sys.stderr)
        return 1
    print('VM input files (host-side identity only; this does not prove guest enforcement):', flush=True)
    for item in run_record['inputsBefore']:
        print('  %s %s  %s' % (item['name'], item['sha256'], item['path']), flush=True)
    print('VM run record: %s' % record_path, flush=True)
    print('VM log: %s' % log.name, flush=True)

    # what each test's output must be: Apple's on the host, or the expected file
    want, wanted, reference_errors = {}, {}, {}
    for name, check, args, expected in tests:
        if check == 'compare':
            data, error = reference_output(name, args)
            if error:
                reference_errors[name] = error
                want[name] = None
            else:
                wanted[name] = data
                want[name] = cksum(wanted[name])
        elif check == 'expected':
            wanted[name] = mask(name, (ROOT / expected).read_bytes())
            want[name] = cksum(wanted[name])

    display_after = capture_display_snapshot()
    display_warnings = apple_reference_display_warnings(display_before, display_after, reference_count)
    run_record['appleReferenceDisplay']['after'] = display_after
    run_record['appleReferenceDisplay']['contextChanged'] = display_context_changed(
        display_before, display_after)
    run_record['appleReferenceDisplay']['warnings'] = display_warnings
    if display_warnings:
        print('Apple reference display warning:')
        for warning in display_warnings:
            print('  ' + warning)
        run_record['appleReferenceDisplay']['limitations'].append(
            'Apple output was still compared as usual; these snapshots do not confirm matching display conditions.'
        )
    try:
        write_run_record(record_path, run_record)
    except OSError as error:
        print('Could not save Apple reference display state: %s' % error, file=sys.stderr)

    commands = []
    for name, check, args, expected in tests:
        out = '/tmp/vmt.out'
        body = 'tail -n +2 %s' % out if check == 'compare' else 'cat %s' % out
        for pattern, replacement in MASKS.get(name, []):
            body += " | sed -E %s" % shlex.quote('s#%s#%s#' % (pattern, replacement))
        made = [VM_DIRS[a] for a in shlex.split(args) if a in VM_DIRS] + ([SETUP[name]] if name in SETUP else [])
        cmd = ''.join('mkdir -p %s; ' % shlex.quote(d) for d in made)
        if name == 'cf-preferences-container-test':
            cmd += 'CFFIXED_USER_HOME=/tmp/finch-vmt-prefs '
        cmd += ('finch-%s %s > %s 2> /tmp/vmt.err & p=$!; (sleep %d; kill -9 $p) 2> /dev/null & w=$!; '
               'wait $p; s=$?; kill $w 2> /dev/null; %s > /tmp/vmt.checked; m=$?; '
               '[ $m -eq 0 ] || s=$m; c=$(cksum < /tmp/vmt.checked); echo "VMT|%s|$s|$c"; '
               % (name, vm_args(args, paths), out, LIMIT, body, name))
        bad = '[ $s -ne 0 ]' if check == 'exit' else '[ $s -ne 0 ] || [ "$c" != "%s" ]' % (want.get(name) or '-')
        cmd += ('if %s; then head -n 2000 /tmp/vmt.checked | sed "s/^/VMOUT|%s|/"; tail -n 40 /tmp/vmt.err | sed "s/^/VMERR|%s|/"; fi; true'
                % (bad, name, name))
        commands.append(cmd)

    commands.insert(0, GUEST_ENV + '; if [ -f /usr/share/finch/development-borrowed-components.txt ]; then printf "\\nVMTBORROWED|sandbox\\n"; fi')
    for attempt in range(2):
        log.seek(0)
        log.truncate()
        status = subprocess.run([str(ROOT / 'tools/vm/with-vm-lock.sh'), 'expect', str(ROOT / 'tools/vm/smoke.exp')] + commands,
                                cwd=ROOT, env=run_env, stdout=log, stderr=subprocess.STDOUT,
                                stdin=subprocess.DEVNULL).returncode
        log.flush()
        text = Path(log.name).read_text(errors='replace')
        if BOOT_FAILED not in text:
            break
        print('the VM stopped before its shell started; booting it again', flush=True)
    log.close()
    text = re.sub(r'\x1b\[[0-9;?]*[A-Za-z]', '', text)
    service_exits = notifyd_exit_messages(text)
    run_record['unexpectedServiceExits'] = [
        {'source': 'vm-tests', 'message': message} for message in service_exits
    ]
    borrowed = borrowed_components(text)
    run_record['mainGuestDeclaredBorrowedComponents'] = sorted(borrowed)
    if borrowed:
        print('Development image: uses the base image sandbox library; this is not release evidence.')
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

    known = exceptions(display_after)
    passed = failed = expected_fail = 0
    for name, check, args, expected in tests:
        unverified = name == 'libsandbox-test' and 'sandbox' in borrowed
        if unverified:
            verdict, ok = 'not verified: base image sandbox library', False
        elif name in reference_errors:
            verdict, ok = reference_errors[name], False
        elif name not in results:
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
                lines = re.findall(r'^VMOUT\|%s\|(.*?)\r?$' % re.escape(name), text, re.M)
                ok = name == 'videotoolbox-test' and video_matches(
                    wanted[name].decode(), '\n'.join(lines))
                verdict = 'ok (lossy video comparison)' if ok else 'DIFFERS from %s' % (
                    "Apple's" if check == 'compare' else 'expected')
            else:
                verdict, ok = 'ok (%s)' % check, True
        if unverified or name in reference_errors:
            failed += 1  # A known Finch difference cannot excuse a broken reference.
        elif name in known:
            if ok and known[name].startswith('1x display'):
                passed += 1  # The host suite treats display exceptions as valid on any 1x screen.
            elif ok:
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
    if service_exits:
        print('notifyd exited unexpectedly during this VM run:')
        for message in service_exits:
            print('  ' + message)
        failed += 1
    if status not in (0, 4):
        print('### the VM run itself failed (smoke.exp exit %d)' % status)
        failed += 1

    script_records = []
    if scripts and not selected:
        for script in SCRIPTS:
            run, script_record = run_test_script(script, run_env, vm_inputs)
            name = ', '.join(SCRIPTS[script]) or script.split('/')[-1]
            script_service_exits = notifyd_exit_messages(run.stdout)
            script_record['unexpectedServiceExits'] = script_service_exits
            run_record['unexpectedServiceExits'].extend(
                {'source': script, 'message': message} for message in script_service_exits
            )
            script_records.append(script_record)
            if run.returncode == 0 and not script_service_exits:
                print('%-36s ok (%s)' % (name, script))
                passed += 1
            else:
                reasons = []
                if run.returncode != 0:
                    reasons.append('exit %d' % run.returncode)
                if script_service_exits:
                    reasons.append('unexpected notifyd exit')
                print('%-36s FAILED (%s: %s)' % (name, script, ', '.join(reasons)))
                sys.stdout.write(run.stdout[-2000:])
                failed += 1
            for input_name, item in script_record['imageOverrides'].items():
                if item.get('verifiedAtLaunch'):
                    print('  %s image at launch: %s  %s' % (
                        input_name, item['sha256AtLaunch'], item['path']))
                else:
                    print('  %s image has no valid launch-time record.' % input_name)
                if 'sha256AfterScript' in item:
                    state = 'unchanged' if item.get('unchangedAfterScript') else 'changed or unverified'
                    print('  %s image after script: %s (%s)' % (
                        input_name, item['sha256AfterScript'], state))
                else:
                    print('  %s image could not be hashed after script: %s' % (
                        input_name, item.get('captureError', item['path'])))
            if script_record['imageEvidenceErrors']:
                print('  image launch evidence is invalid:')
                for error in script_record['imageEvidenceErrors']:
                    print('    %s' % error)
                failed += 1

    try:
        hashes_after = vm_input_hashes(vm_inputs)
        inputs_unchanged = hashes_after == hashes_before
        run_record['inputsAfter'] = vm_input_record(vm_inputs, hashes_after)
        run_record['inputsUnchanged'] = inputs_unchanged
        run_record['finishedAt'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        run_record['vmExitCode'] = status
        run_record['scripts'] = script_records
        write_run_record(record_path, run_record)
    except (OSError, ValueError) as error:
        inputs_unchanged = False
        print('Could not verify or save VM input identities after the run: %s' % error)
    if not inputs_unchanged:
        print('VM input files changed or could not be verified after the run; this run is not valid evidence.')
        failed += 1
    else:
        print('VM input files are unchanged after the run.')

    print('%d passed, %d failed, %d known failures' % (passed, failed, expected_fail))
    if failed:
        print('failed tests\' output: %s (diff NAME.want NAME.vm)' % OUTPUTS.relative_to(ROOT))
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
