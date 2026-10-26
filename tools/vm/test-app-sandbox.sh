#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# The App Sandbox (libsystem_secinit and application.sb): two sandboxed apps,
# run as a user finch-app-sandbox-test makes, check their containers, what's
# closed to them and what their entitlements open. It runs on the persistent
# VM, whose homes are real, with a fresh copy of the empty data disk.
# Build the images first:
#
#   tools/vm/mkramdisk.sh && tools/vm/mkpersistent.sh && tools/vm/test-app-sandbox.sh
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
out="${root}/build/vm-persistent"
[[ -f "${out}/data-empty.img" ]] || { echo "no empty data disk; run tools/vm/mkpersistent.sh" >&2; exit 2; }
disk="${out}/test-app-sandbox.img"
rm -f "${disk}"
cp -c "${out}/data-empty.img" "${disk}"
export FINCH_DATA_IMAGE="${disk}" FINCH_PERSISTENT=1
cd "${root}"
tools/vm/with-vm-lock.sh expect tools/vm/smoke.exp 'finch-app-sandbox-test' < /dev/null
rm -f "${disk}"
