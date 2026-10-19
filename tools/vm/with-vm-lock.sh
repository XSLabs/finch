#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Run a command holding the VM lock, so that several people (or agents)
# building ramdisks and booting the QEMU VM don't trip over each other.
#
#   tools/vm/with-vm-lock.sh tools/vm/mkramdisk.sh
#   tools/vm/with-vm-lock.sh --try tools/vm/finalize-system-accounts.sh --locked
#   tools/vm/with-vm-lock.sh sh -c 'tools/vm/mkramdisk.sh && expect tools/vm/smoke.exp "finch-foo-test | cksum"'
set -euo pipefail
try=0
if [[ "${1:-}" == "--try" ]]; then
    try=1
    shift
fi
if [[ $# -eq 0 ]]; then
    echo "usage: $0 [--try] COMMAND [ARG ...]" >&2
    exit 2
fi
lock=/tmp/finch-vm.lock
until mkdir "$lock" 2>/dev/null; do
    # a lock left by a process that has gone
    # A sandbox can deny process checks even while the owner is alive. Only
    # "no such process" proves that it is safe to remove an old lock.
    if [[ -f "$lock/pid" ]] && python3 - "$lock/pid" <<'PY'
import os
import sys

try:
    with open(sys.argv[1]) as source:
        pid = int(source.read().strip())
    if pid <= 0:
        sys.exit(1)
    os.kill(pid, 0)
except ProcessLookupError:
    sys.exit(0)
except (OSError, ValueError):
    pass
sys.exit(1)
PY
    then
        rm -rf "$lock"
        continue
    fi
    if [[ "$try" == 1 ]]; then
        echo "VM lock is already held; wait for the VM work to finish, then retry" >&2
        exit 1
    fi
    sleep 5
done
echo $$ > "$lock/pid"
trap 'rm -rf "$lock"' EXIT
"$@"
