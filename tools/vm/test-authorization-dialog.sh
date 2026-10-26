#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Authorization's password dialog (finch-securityagent, asked by authd):
# finch-authorization-dialog-test runs a tool as an ordinary user, in that
# user's domain, on a headless window server, and answers the dialog from the
# keyboard: a wrong password, the right one, then Escape. It runs on the
# persistent VM, with a fresh copy of the empty data disk.
# Build the images first:
#
#   tools/vm/mkramdisk.sh && tools/vm/mkpersistent.sh && tools/vm/test-authorization-dialog.sh
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
out="${root}/build/vm-persistent"
[[ -f "${out}/data-empty.img" ]] || { echo "no empty data disk; run tools/vm/mkpersistent.sh" >&2; exit 2; }
disk="${out}/test-authorization-dialog.img"
rm -f "${disk}"
cp -c "${out}/data-empty.img" "${disk}"
export FINCH_DATA_IMAGE="${disk}" FINCH_PERSISTENT=1
cd "${root}"
tools/vm/with-vm-lock.sh expect tools/vm/smoke.exp 'finch-authorization-dialog-test' < /dev/null
rm -f "${disk}"
