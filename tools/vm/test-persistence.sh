#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# The stored-data check (docs/ROADMAP.md, Finch 1.0): make a user, save files and
# change the password, shut down, then boot twice more and read the same data back
# with the same access rules. Uses a fresh copy of the empty data disk, never
# build/vm-persistent/data.img. Build the images first:
#
#   tools/vm/mkramdisk.sh && tools/vm/mkpersistent.sh && tools/vm/test-persistence.sh
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
out="${root}/build/vm-persistent"
[[ -f "${out}/data-empty.img" ]] || { echo "no empty data disk; run tools/vm/mkpersistent.sh" >&2; exit 2; }
disk="${out}/test-data.img"
rm -f "${disk}"
cp -c "${out}/data-empty.img" "${disk}"
export FINCH_DATA_IMAGE="${disk}"
cd "${root}"
run() { tools/vm/with-vm-lock.sh expect tools/vm/persistence.exp "$@" < /dev/null; }
run first
run again 2
run again 3
rm -f "${disk}"
echo "persistence: accounts, a changed password, home files and their modes survived two restarts"
