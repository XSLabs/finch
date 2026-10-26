#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Authorization Services through Finch's authd (userland/authd): rights,
# passwords, shared credentials, external forms and privileged tools, checked by
# finch-authorization-test as two accounts it makes. It runs on the persistent
# VM, whose account files are writable, with a fresh copy of the empty data disk.
# Build the images first:
#
#   tools/vm/mkramdisk.sh && tools/vm/mkpersistent.sh && tools/vm/test-authorization.sh
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
out="${root}/build/vm-persistent"
[[ -f "${out}/data-empty.img" ]] || { echo "no empty data disk; run tools/vm/mkpersistent.sh" >&2; exit 2; }
disk="${out}/test-authorization.img"
rm -f "${disk}"
cp -c "${out}/data-empty.img" "${disk}"
export FINCH_DATA_IMAGE="${disk}" FINCH_PERSISTENT=1
cd "${root}"
tools/vm/with-vm-lock.sh expect tools/vm/smoke.exp 'finch-authorization-test' < /dev/null
rm -f "${disk}"
