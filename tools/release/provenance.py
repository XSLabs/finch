#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""The release's source record and licence notices.

    tools/release/provenance.py [--root build/root] [--check]

For every project pinned in userland/projects.txt and
userland/third-party-projects.txt (and XNU, pinned in tools/build-kernel.sh)
whose checkout is in build/src:

  - the checkout must be at exactly its pinned tag;
  - any local change to a tracked file must be one Finch's build makes: its
    patches for the project (userland/patches/<project>/*.patch, and the
    cache builder's and kernel's below), each of which must be applied; build-oss's
    rewrite of an xcconfig's BSD.xcconfig include; or a file the project's own
    build regenerates (userland/oss/<project>.generated). Anything else stops
    the build;
  - its licence goes to /usr/share/finch/licenses/<project>/ unless a recipe
    already installed notices there: the project's licence files (LICENSE,
    COPYING, APPLE_LICENSE and the like, at its top or one level down), or,
    where it has none, the notices its source files carry
    (tools/collect-notices.py).

It writes /usr/share/finch/SOURCES.txt: each project, its tag, the commit it
resolved to, where it came from, and the patches applied. --check only
verifies (no files written).
"""
import argparse
import fnmatch
import glob
import os
import re
import shutil
import subprocess
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
SRC = os.path.join(ROOT, 'build', 'src')
LICENCE_NAME = re.compile(r'^(APPLE_LICENSE|APSL.*|LICEN[CS]E.*|COPYING.*|COPYRIGHT.*|NOTICE.*)$', re.I)
SOURCE_SUFFIXES = ('.c', '.h', '.m', '.cpp', '.cc', '.s')


def git(path, *args):
    return subprocess.run(['git', '-C', path, *args], capture_output=True, text=True)


def pins():
    out = []
    for name in ('projects.txt', 'third-party-projects.txt'):
        path = os.path.join(ROOT, 'userland', name)
        if not os.path.exists(path):
            continue
        for line in open(path):
            fields = line.split()
            if not fields or fields[0].startswith('#'):
                continue
            url = fields[2] if len(fields) > 2 else f'https://github.com/apple-oss-distributions/{fields[0]}.git'
            out.append((fields[0], fields[1], url))
    kernel = open(os.path.join(ROOT, 'tools', 'build-kernel.sh')).read()
    m = re.search(r'(xnu-\d+(?:\.\d+)*)', kernel)
    if m:
        out.append(('xnu', m.group(1), 'https://github.com/apple-oss-distributions/xnu.git'))
    return out


def checkout(name):
    for candidate in (os.path.join(SRC, name), os.path.join(ROOT, 'build', 'xnu-work', name)):
        if os.path.isdir(os.path.join(candidate, '.git')) or os.path.isfile(os.path.join(candidate, '.git')):
            return candidate
    return None


# Finch's patch sets kept elsewhere: the shared-cache builder's (tools/dsc) and the kernel's.
EXTRA_PATCHES = {
    'dyld': ['tools/dsc/patches'],
    'xnu': ['kernel/patches'],
}
# Third-party build tools that edit a checkout (pinned submodules): the files
# their scripts and patches name may change; their patches needn't all apply
# (darwin-xnu-build skips those already upstream).
TOOL_EDITS = {
    'xnu': ['tools/darwin-xnu-build/build.sh', 'tools/darwin-xnu-build/patches/26.0'],
}
BSD_XCCONFIG = re.compile(r'^[-+](//)?#include ".*(Makefiles/CoreOS/Xcode/BSD\.xcconfig|userland/sdk/BSD\.xcconfig)"$')


def tool_edits(project):
    """The text of the scripts and patches that third-party build tools apply."""
    text = ''
    for entry in TOOL_EDITS.get(project, []):
        path = os.path.join(ROOT, entry)
        for f in [path] if os.path.isfile(path) else sorted(glob.glob(os.path.join(path, '*'))):
            text += open(f, errors='replace').read()
    return text


def edited_by_tool(text, f):
    """A file a tool's script or patch names, or one in a folder it writes into."""
    if not text:
        return False
    if f in text:
        return True
    parts = f.split('/')[:-1]
    # (the folder, or its last two or more parts: scripts name paths through variables)
    return any('/'.join(parts[i:]) in text for i in range(0, len(parts) - 1))


# XNU: Finch's kernel patches build on each other (one only starts a file another
# replaces), so tools/build-kernel.sh stamps the series it applied in full; and
# Finch's own kernel sources are copied over what the patches start.
SERIES_STAMP = {'xnu': ('.finch-patch-series', 'kernel/patches')}
COPIED_SOURCES = {'xnu': [('kernel/sandbox/finch_sandbox.c', 'security/finch_sandbox.c'),
                          ('kernel/sandbox/fsb_eval.c', 'security/fsb_eval.c'),
                          ('kernel/sandbox/fsb_format.h', 'security/fsb_format.h'),
                          ('kernel/sandbox/fsb_ops.h', 'security/fsb_ops.h'),
                          ('kernel/include/finch_sandbox_abi.h', 'security/finch_sandbox_abi.h'),
                          ('kernel/sandbox/FinchSandboxIOKit.cpp', 'iokit/Kernel/FinchSandboxIOKit.cpp')]}


def series_applied(project, path):
    stamp_name, patch_dir = SERIES_STAMP[project]
    import hashlib
    series = hashlib.sha256(b''.join(open(p, 'rb').read()
                                     for p in sorted(glob.glob(os.path.join(ROOT, patch_dir, '*.patch')))))
    try:
        return open(os.path.join(path, stamp_name)).read().strip() == series.hexdigest()
    except OSError:
        return False


def xcconfig_rewrite_only(path, f):
    """Is the file's only change build-oss's BSD.xcconfig include?"""
    if not f.endswith('.xcconfig'):
        return False
    diff = git(path, 'diff', '-U0', '--', f).stdout.splitlines()
    changes = [l for l in diff if l[:1] in '+-' and not l.startswith(('+++', '---'))]
    return bool(changes) and all(BSD_XCCONFIG.match(l) for l in changes)


def generated(project):
    path = os.path.join(ROOT, 'userland', 'oss', project + '.generated')
    if not os.path.exists(path):
        return []
    return [l.strip() for l in open(path) if l.strip() and not l.startswith('#')]


def patched_files(project):
    """The files Finch's patches for this project change, and the patches not applied."""
    files, unapplied, names = set(), [], []
    path = checkout(project)
    dirs = [os.path.join(ROOT, 'userland', 'patches', project)] + \
        [os.path.join(ROOT, d) for d in EXTRA_PATCHES.get(project, [])]
    for d in dirs:
        patches = sorted(glob.glob(os.path.join(d, '*.patch')))
        for patch in patches:
            names.append(os.path.basename(patch))
            for line in open(patch, errors='replace'):
                if line.startswith('+++ ') or line.startswith('--- '):
                    f = line[4:].strip().split('\t')[0]
                    if f != '/dev/null':
                        files.add(f[2:] if f[:2] in ('a/', 'b/') else f)
        # Applied in order, each on the last: undone in reverse, together.
        rel = os.path.relpath(d, ROOT)
        if project in SERIES_STAMP and SERIES_STAMP[project][1] == rel:
            if not series_applied(project, path):
                unapplied.append(rel)
        elif patches and git(path, 'apply', '--check', '--reverse', *reversed(patches)).returncode != 0:
            unapplied.append(rel)
    return files, unapplied, names


def licence_files(path, depth):
    """Licence files at the top (depth 0) or one folder down (depth 1)."""
    found = []
    dirs = [path] if depth == 0 else [os.path.join(path, d) for d in sorted(os.listdir(path))
                                     if os.path.isdir(os.path.join(path, d)) and not d.startswith('.')
                                     and not re.match(r'(?i)tests?$', d)]
    for d in dirs:
        for entry in sorted(os.listdir(d)):
            f = os.path.join(d, entry)
            if os.path.isfile(f) and LICENCE_NAME.match(entry):
                found.append(f)
    return found


MARKER = '.from-provenance'


def install_notices(name, path, dest_root):
    """The project's notices, unless its recipe installed them (folders this step
    made carry a marker and are made again)."""
    dest = os.path.join(dest_root, 'usr', 'share', 'finch', 'licenses', name)
    if glob.glob(dest + '*') and not os.path.exists(os.path.join(dest, MARKER)):
        return 'installed by its recipe'
    shutil.rmtree(dest, ignore_errors=True)
    os.makedirs(dest)
    open(os.path.join(dest, MARKER), 'w').close()
    copied = []
    top = licence_files(path, 0)
    # No licence at the top: the notices its files carry, and its components' licences.
    for f in top or licence_files(path, 1):
        rel = os.path.relpath(f, path)
        shutil.copyfile(f, os.path.join(dest, rel.replace(os.sep, '-')))
        os.chmod(os.path.join(dest, rel.replace(os.sep, '-')), 0o644)
        copied.append(rel)
    if top:
        return 'licence files: ' + ', '.join(copied)
    sources = []
    for root, dirs, names in os.walk(path):
        dirs[:] = [d for d in dirs if not d.startswith('.') and not re.match(r'(?i)tests?$', d)]
        sources += [os.path.join(root, n) for n in names if n.endswith(SOURCE_SUFFIXES)]
    out = os.path.join(dest, 'NOTICES.txt')
    subprocess.run([sys.executable, os.path.join(ROOT, 'tools', 'collect-notices.py'), name, out] + sources[:4000],
                   check=True, capture_output=True)
    os.chmod(out, 0o644)
    note = f'notices collected from {min(len(sources), 4000)} source files'
    return note + (', with ' + ', '.join(copied) if copied else '')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', default=os.path.join(ROOT, 'build', 'root'))
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    problems, lines = [], []
    for name, tag, url in pins():
        path = checkout(name)
        if path is None:
            lines.append(f'{name}\t{tag}\tnot built\t{url}')
            continue
        have = git(path, 'describe', '--tags', '--exact-match').stdout.strip()
        if have != tag:
            problems.append(f'{name}: checkout is at {have or "an untagged commit"}, pinned {tag}')
        commit = git(path, 'rev-parse', 'HEAD').stdout.strip()
        changed = {l[3:].split(' -> ')[-1] for l in git(path, 'status', '--porcelain', '--untracked-files=no')
                   .stdout.splitlines() if l.strip()}
        patched, unapplied, patch_names = patched_files(name)
        for p in unapplied:
            problems.append(f'{name}: Finch\'s patches in {p} are not all applied')
        for source, copy in COPIED_SOURCES.get(name, []):
            a, b = os.path.join(ROOT, source), os.path.join(path, copy)
            if not os.path.exists(b) or open(a, 'rb').read() != open(b, 'rb').read():
                problems.append(f'{name}: {copy} isn\'t Finch\'s {source}')
        made = generated(name)
        tools = tool_edits(name)
        for f in sorted(changed - patched):
            if xcconfig_rewrite_only(path, f) or any(fnmatch.fnmatch(f, g) for g in made) or \
                    edited_by_tool(tools, f):
                continue
            problems.append(f'{name}: {f} is changed, but no Finch patch changes it')
        notice = 'checked' if args.check else install_notices(name, path, args.root)
        lines.append(f'{name}\t{tag}\t{commit}\t{url}\t'
                     f'patches: {", ".join(patch_names) if patch_names else "none"}\t{notice}')
    if problems:
        print('provenance: the sources are not as pinned:', file=sys.stderr)
        for p in problems:
            print('  ' + p, file=sys.stderr)
        return 1
    if not args.check:
        out = os.path.join(args.root, 'usr', 'share', 'finch', 'SOURCES.txt')
        os.makedirs(os.path.dirname(out), exist_ok=True)
        with open(out, 'w') as f:
            f.write('# The sources this Finch was built from: project, tag, commit, origin, Finch\'s patches,\n'
                    '# and where its licence notice is (/usr/share/finch/licenses/<project>/).\n')
            f.write('\n'.join(lines) + '\n')
        os.chmod(out, 0o644)
    print(f'provenance: {len(lines)} projects, all at their pinned tags with only Finch\'s patches')
    return 0


if __name__ == '__main__':
    sys.exit(main())
