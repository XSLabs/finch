#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# A new system's first boot: finch-setup makes the first account at the
# console and login lets it in (tools/vm/first-user.exp). Uses a fresh copy of
# the new-system data disk. Build the images first:
#
#   tools/vm/mkramdisk.sh && tools/vm/mkpersistent.sh && tools/vm/test-first-user.sh
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
out="${root}/build/vm-persistent"
[[ -f "${out}/data-new-system-empty.img" ]] || { echo "no new-system disk; run tools/vm/mkpersistent.sh" >&2; exit 2; }
disk="${out}/test-new-system.img"
rm -f "${disk}"
cp -c "${out}/data-new-system-empty.img" "${disk}"
export FINCH_DATA_IMAGE="${disk}"
cd "${root}"
tools/vm/with-vm-lock.sh expect tools/vm/first-user.exp < /dev/null
rm -f "${disk}"
