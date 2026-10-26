#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Build build/vm-persistent: a development VM whose accounts and home folders
# survive restarts (docs/design/PERSISTENT_VM_STORAGE.md).
#
#   tools/vm/mkpersistent.sh              # then: FINCH_PERSISTENT=1 tools/vm/run.sh
#
#   system.dmg   the VM image (build/vm/ramdisk.dmg) as a new APFS volume, set up
#                to mount its data volume at boot: the account files are links
#                into it, and every file has the owner and mode the release rules
#                give it (set as root in the guest; see tools/vm/image-owners.py)
#   data.img     the data disk: accounts, home folders, /var/db. Made once and
#                kept; rebuilding the system image keeps its data.
#   data-empty.img  a clone of the data disk as first laid out, for tests
#
# Needs build/vm/ramdisk.dmg (tools/vm/mkramdisk.sh) and a kernel collection with
# the PCIe bridge (tools/build-kernel.sh links it in, boot/kc/extra-kexts.txt).
# FINCH_DATA_SIZE sizes a new data disk (default 4g). No sudo needed.
set -euo pipefail

FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VM="${FINCH_ROOT}/build/vm"
OUT="${FINCH_ROOT}/build/vm-persistent"
KC="${FINCH_ROOT}/third_party/darwin-vm/firmware/bootkc"
die() { echo "mkpersistent: $*" >&2; exit 1; }

[[ -f "${VM}/ramdisk.dmg" && -f "${VM}/ramdisk.tc" ]] || die "no VM image; run tools/vm/mkramdisk.sh"
grep -q com.apple.driver.AppleVirtualPlatform "${KC}" \
    || die "the boot kernel collection has no PCIe bridge; run tools/build-kernel.sh --link-only --install"
mkdir -p "${OUT}"
rm -f "${OUT}"/*.new.cdr

# The UUID of an image's one APFS volume.
volume_uuid() {
    python3 - "$1" <<'PY'
import plistlib
import subprocess
import sys

attach = subprocess.run(['hdiutil', 'attach', '-readonly', '-nomount', '-plist',
                         '-imagekey', 'diskimage-class=CRawDiskImage', sys.argv[1]],
                        check=True, capture_output=True).stdout
disks = {e['dev-entry'].removeprefix('/dev/') for e in plistlib.loads(attach)['system-entities']}
try:
    listing = plistlib.loads(subprocess.run(['diskutil', 'apfs', 'list', '-plist'],
                                            check=True, capture_output=True).stdout)
    uuids = [v['APFSVolumeUUID'] for c in listing['Containers']
             if any(s['DeviceIdentifier'] in disks for s in c['PhysicalStores'])
             for v in c['Volumes']]
finally:
    subprocess.run(['hdiutil', 'detach', '/dev/' + min(disks, key=len)], check=True,
                   capture_output=True)
if len(uuids) != 1:
    raise SystemExit(f'{sys.argv[1]}: expected one APFS volume, found {len(uuids)}')
print(uuids[0])
PY
}

mnt=""
cleanup() {
    # (an if, not &&: the trap's last status is the script's)
    if [[ -n "${mnt}" ]]; then
        hdiutil detach "${mnt}" >/dev/null 2>&1 || true
        rmdir "${mnt}" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# 1. The data disk, made once.
data="${OUT}/data.img"
new_data=0
if [[ ! -f "${data}" ]]; then
    echo "==> new data disk (${FINCH_DATA_SIZE:-4g})"
    hdiutil create -quiet -size "${FINCH_DATA_SIZE:-4g}" -layout GPTSPUD -fs APFS \
        -volname FinchData -type UDTO "${OUT}/data.new" >/dev/null
    data="${OUT}/data.new.cdr"
    new_data=1
fi
data_uuid=$(volume_uuid "${data}")
echo "    data volume ${data_uuid}"

# 2. The system image: a copy of the VM image's files in a new volume (a copy of
#    the image file would have the same volume UUID as the setup boot's root).
echo "==> system image from build/vm/ramdisk.dmg"
mnt=$(mktemp -d)
hdiutil attach -readonly -owners off -nobrowse -mountpoint "${mnt}" \
    -imagekey diskimage-class=CRawDiskImage "${VM}/ramdisk.dmg" >/dev/null
hdiutil create -quiet -srcfolder "${mnt}" -srcowners off -fs APFS -layout NONE \
    -format UDTO -size "${RAMDISK_SIZE:-1g}" -volname FinchSystem "${OUT}/system.new" >/dev/null
hdiutil detach "${mnt}" >/dev/null
system="${OUT}/system.new.cdr"

hdiutil attach -owners off -nobrowse -mountpoint "${mnt}" \
    -imagekey diskimage-class=CRawDiskImage "${system}" >/dev/null
# Accounts live on the data volume; the image keeps the templates it's seeded from.
mkdir -p "${mnt}/usr/share/finch/accounts"
for name in master.passwd passwd group; do
    [[ -f "${mnt}/private/etc/${name}" && ! -L "${mnt}/private/etc/${name}" ]] \
        || die "the VM image has no plain /etc/${name}"
    mv "${mnt}/private/etc/${name}" "${mnt}/usr/share/finch/accounts/${name}"
    ln -s "/private/var/rw/accounts/${name}" "${mnt}/private/etc/${name}"
done
printf '%s\n' "${data_uuid}" > "${mnt}/private/etc/finch/data-volume"
printf '/private/var/rw/accounts\n' > "${mnt}/private/etc/finch/account-store"
chmod 644 "${mnt}/private/etc/finch/data-volume" "${mnt}/private/etc/finch/account-store"
# Root's home is on the data volume too.
rmdir "${mnt}/private/var/root" || die "/private/var/root in the VM image isn't an empty folder"
ln -s rw/root "${mnt}/private/var/root"
# So is /Library, as on macOS's Data volume: system-wide preferences, among
# them configd's network settings (Preferences/SystemConfiguration).
[[ -z "$(find "${mnt}/Library" -type f -print -quit)" ]] \
    || die "the VM image's /Library holds files; the data volume's would hide them"
rm -rf "${mnt}/Library"
ln -s private/var/rw/Library "${mnt}/Library"
python3 "${FINCH_ROOT}/tools/vm/image-owners.py" "${mnt}"
hdiutil detach "${mnt}" >/dev/null
rmdir "${mnt}"
mnt=""
system_uuid=$(volume_uuid "${system}")
echo "    system volume ${system_uuid}"

# 3. In the guest, as root: owners and modes, and a new data disk's layout.
commands=("/usr/local/bin/finch-volume-setup system ${system_uuid}")
(( new_data )) && commands+=("/usr/local/bin/finch-volume-setup data ${data_uuid} ${system_uuid}")
echo "==> setting up in the guest"
FINCH_DATA_IMAGE="${data}" FINCH_SETUP_IMAGE="${system}" \
    "${FINCH_ROOT}/tools/vm/with-vm-lock.sh" expect "${FINCH_ROOT}/tools/vm/smoke.exp" "${commands[@]}" \
    < /dev/null > "${OUT}/setup.log" 2>&1 || die "guest setup failed; see ${OUT}/setup.log"
grep -a 'finch-volume-setup:' "${OUT}/setup.log" | tr -d '\r' | sed 's/^/    /'

mv "${system}" "${OUT}/system.dmg"
if (( new_data )); then
    mv "${data}" "${OUT}/data.img"
    # The empty disk, for tests that need a fresh one (tools/vm/test-persistence.sh).
    cp -c "${OUT}/data.img" "${OUT}/data-empty.img"
fi
# The same programs as the VM image, so the same trust cache.
cp "${VM}/ramdisk.tc" "${OUT}/ramdisk.tc"
echo "built ${OUT}/system.dmg and $( (( new_data )) && echo new || echo kept) data.img; boot with FINCH_PERSISTENT=1 tools/vm/run.sh"
