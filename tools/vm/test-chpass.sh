#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# chpass, chsh and chfn through Finch's OpenDirectory and its account helper,
# checked by finch-chpass-test as accounts it makes: their own shell and
# finger information, refusals, an administrator's and root's changes. It runs
# on the persistent VM, whose account files are writable and whose helper is
# setuid root, with a fresh copy of the empty data disk.
# Build the images first:
#
#   tools/vm/mkramdisk.sh && tools/vm/mkpersistent.sh && tools/vm/test-chpass.sh
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
out="${root}/build/vm-persistent"
[[ -f "${out}/data-empty.img" ]] || { echo "no empty data disk; run tools/vm/mkpersistent.sh" >&2; exit 2; }
disk="${out}/test-chpass.img"
rm -f "${disk}"
cp -c "${out}/data-empty.img" "${disk}"
export FINCH_DATA_IMAGE="${disk}" FINCH_PERSISTENT=1
cd "${root}"
tools/vm/with-vm-lock.sh expect tools/vm/smoke.exp 'finch-chpass-test' < /dev/null
rm -f "${disk}"
