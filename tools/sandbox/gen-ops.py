#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Write kernel/sandbox/fsb_ops.h from tools/sandbox/ops.txt.

    tools/sandbox/gen-ops.py
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ops = [l.strip() for l in (ROOT / 'tools/sandbox/ops.txt').read_text().splitlines()
       if l.strip() and not l.startswith('#')]


def parent(i):
    """The nearest group ('x*') whose prefix this name extends; default otherwise."""
    name = ops[i]
    if name == 'default':
        return None
    best = None
    for j, group in enumerate(ops):
        if j == i or not group.endswith('*'):
            continue
        prefix = group[:-1]
        if name.startswith(prefix) and len(prefix) < len(name.rstrip('*')) \
                and (best is None or len(prefix) > len(ops[best]) - 1):
            best = j
    return 0 if best is None else best


def ident(name):
    return 'FSB_OP_' + name.replace('*', '_ALL').replace('-', '_').replace('.', '_').upper()


out = ['/* SPDX-License-Identifier: MIT OR Apache-2.0 */', '/*',
       " * Sandbox operation names, as SBPL profiles spell them (macOS 26.4's set, in",
       " * its order). A name ending in '*' is a group: rules on it apply to every",
       ' * operation it prefixes that has no matching rule of its own. FSB_OP_* index',
       ' * this table; compiled profiles store rules per index, so the order is ABI.',
       " * FSB_OP_PARENTS gives each operation's nearest group, and default's for",
       ' * ungrouped ones (default itself has none).', ' *',
       " * Generated from the names by tools/sandbox/gen-ops.py; don't edit by hand.",
       ' */', '#ifndef FSB_OPS_H', '#define FSB_OPS_H', '']
out += [f'#define {ident(o):<56} {i}' for i, o in enumerate(ops)]
out += [f'#define FSB_OP_COUNT {len(ops)}', '', '#define FSB_OP_NAMES \\']
out += [f'\t"{o}", \\' for o in ops]
out += ['', '#define FSB_OP_PARENTS \\']
for i, o in enumerate(ops):
    p = parent(i)
    out.append(f'\t{"0xffffffffu" if p is None else p}, /* {o} -> {"-" if p is None else ops[p]} */ \\')
out += ['', '#endif /* FSB_OPS_H */', '']
(ROOT / 'kernel/sandbox/fsb_ops.h').write_text('\n'.join(out))
