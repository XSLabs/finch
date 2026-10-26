#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# A second disk through Disk Arbitration (tools/vm/disks.exp): the host makes a
# FAT disk with a file, the persistent VM mounts it at startup, the user at the
# console writes to it, and the user's file is on it afterwards. Build the images first:
#
#   tools/vm/mkramdisk.sh && tools/vm/mkpersistent.sh && tools/vm/test-disks.sh
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
out="${root}/build/vm-persistent"
[[ -f "${out}/data-empty.img" ]] || { echo "no empty data disk; run tools/vm/mkpersistent.sh" >&2; exit 2; }
work="$(mktemp -d)"
mnt=""
cleanup() {
    if [[ -n "${mnt}" ]]; then
        hdiutil detach "${mnt}" >/dev/null 2>&1 || true
    fi
    rm -f "${work}/fat.cdr" "${out}/test-disks.img"
    rmdir "${work}/mnt" "${work}" 2>/dev/null || true
}
trap cleanup EXIT
hdiutil create -quiet -size 64m -fs MS-DOS -volname FINCHDISK -layout MBRSPUD -type UDTO "${work}/fat" >/dev/null
mkdir "${work}/mnt"
mnt="${work}/mnt"
hdiutil attach -quiet -nobrowse -mountpoint "${mnt}" "${work}/fat.cdr"
printf 'written on the host\n' > "${mnt}/hello.txt"
hdiutil detach -quiet "${mnt}"
mnt=""
cp -c "${out}/data-empty.img" "${out}/test-disks.img"
cd "${root}"
FINCH_DATA_IMAGE="${out}/test-disks.img" FINCH_SETUP_IMAGE="${work}/fat.cdr" \
    tools/vm/with-vm-lock.sh expect tools/vm/disks.exp < /dev/null
hdiutil attach -quiet -readonly -nobrowse -mountpoint "${work}/mnt" "${work}/fat.cdr"
mnt="${work}/mnt"
[[ "$(cat "${mnt}/guest.txt")" == "written by diskuser in Finch" ]] \
    || { echo "test-disks: the user's file isn't on the disk" >&2; exit 1; }
echo "test-disks: the host reads the file the user wrote in Finch"
