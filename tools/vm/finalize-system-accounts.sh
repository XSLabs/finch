#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Fix ownership on the disposable Finch VM ramdisk without touching firmware.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd -P)"
VM_DIR="${ROOT}/build/vm"
IMAGE="${VM_DIR}/ramdisk.dmg"
TEMPLATE="${ROOT}/userland/release/etc"
HELPER="/private/tmp/finch-system-accounts/system-account-merge"
LOCK="/tmp/finch-vm.lock"

die() {
    echo "finalize-system-accounts: $*" >&2
    exit 1
}

if [[ "${1:-}" != "--locked" ]]; then
    [[ $# -eq 0 ]] || die "this command takes no image path or other options"
    exec "${ROOT}/tools/vm/with-vm-lock.sh" --try "$0" --locked
fi
shift
[[ $# -eq 0 ]] || die "this command takes no image path or other options"
[[ "$EUID" -eq 0 ]] || die "run this command with sudo so the image keeps root:wheel ownership"

# Only the lock wrapper may enter the protected part of this script.
[[ -f "${LOCK}/pid" ]] || die "VM lock is missing; run through with-vm-lock.sh"
lock_pid="$(/bin/cat "${LOCK}/pid")" || die "cannot read the VM lock"
[[ "$lock_pid" == "$PPID" ]] || die "VM lock is not held by this command"

[[ -d "$VM_DIR" && ! -L "${ROOT}/build" && ! -L "$VM_DIR" ]] ||
    die "build/vm must be a real directory inside this checkout"
[[ -f "$IMAGE" && ! -L "$IMAGE" ]] ||
    die "the only image this command can change is build/vm/ramdisk.dmg"
[[ -d "$TEMPLATE" && ! -L "$TEMPLATE" ]] ||
    die "the release account template is missing or unsafe"
[[ -x "$HELPER" && -f "$HELPER" && ! -L "$HELPER" ]] ||
    die "build the account helper first with: make -C userland/system-accounts"

CALLER_UID="${SUDO_UID:-0}"
/usr/bin/python3 - "$IMAGE" "$VM_DIR" "$HELPER" "$CALLER_UID" <<'PY' ||
import os
import stat
import sys

image, vm_dir, helper, caller_uid = sys.argv[1:]
try:
    expected_owner = int(caller_uid)
except ValueError:
    raise SystemExit("invalid sudo caller identity")

for path in (vm_dir, image, helper, os.path.dirname(helper)):
    st = os.lstat(path)
    if path == vm_dir or path == os.path.dirname(helper):
        if not stat.S_ISDIR(st.st_mode) or st.st_mode & 0o022:
            raise SystemExit("build or account-helper directory must be a non-writable real directory")
    else:
        if not stat.S_ISREG(st.st_mode) or st.st_nlink != 1 or st.st_mode & 0o022:
            raise SystemExit(f"unsafe file: {path}")
if os.lstat(helper).st_uid != expected_owner:
    raise SystemExit("account helper must be built by the user who invoked sudo")
PY
    die "unsafe image, helper, or build/vm path"

HELPER_DIR="$(/usr/bin/dirname "$HELPER")"
[[ ! -L "$HELPER_DIR" ]] || die "account helper directory must not be a symlink"

if /usr/sbin/lsof -nP "$IMAGE" >/dev/null 2>&1; then
    die "the ramdisk is open by a running process; stop the VM and retry"
fi

HDIUTIL_INFO="$(/usr/bin/hdiutil info -plist)" || die "cannot check attached disk images"
ATTACH_STATE="$(/usr/bin/python3 -c '
import os
import plistlib
import sys

wanted = os.path.realpath(sys.argv[1])
try:
    data = plistlib.load(sys.stdin.buffer)
except Exception as error:
    raise SystemExit(f"cannot read hdiutil status: {error}")
print("attached" if any(os.path.realpath(item.get("image-path", "/")) == wanted
                         for item in data.get("images", [])) else "free")
' "$IMAGE" <<<"$HDIUTIL_INFO")" || die "cannot check whether the ramdisk is attached"
[[ "$ATTACH_STATE" == "free" ]] || die "the ramdisk is already attached; stop the VM and retry"
STAGE_DIR=""
STAGE=""
MOUNT=""
BACKUP=""
DEVICE=""
MOUNTED=0
REPLACED=0
COMMITTED=0
PRESERVE_STAGE=0

mounted_device() {
    local info
    info="$(/usr/bin/hdiutil info -plist)" || return 2
    printf '%s' "$info" | /usr/bin/python3 -c '
import os
import plistlib
import sys

stage = os.path.realpath(sys.argv[1])
try:
    data = plistlib.load(sys.stdin.buffer)
except Exception:
    raise SystemExit(2)
matched_image = False
for image in data.get("images", []):
    path = image.get("image-path")
    if not path or os.path.realpath(path) != stage:
        continue
    matched_image = True
    for entity in image.get("system-entities", []):
        if entity.get("dev-entry"):
            print(entity["dev-entry"])
            raise SystemExit(0)
if matched_image:
    raise SystemExit(3)
raise SystemExit(1)
' "$STAGE"
}

staging_mount_matches() {
    local info
    info="$(/usr/bin/hdiutil info -plist)" || return 2
    printf '%s' "$info" | /usr/bin/python3 -c '
import os
import plistlib
import sys

stage, mount = (os.path.realpath(value) for value in sys.argv[1:])
try:
    data = plistlib.load(sys.stdin.buffer)
except Exception:
    raise SystemExit(2)
for image in data.get("images", []):
    path = image.get("image-path")
    if not path or os.path.realpath(path) != stage:
        continue
    if any(entity.get("mount-point") and os.path.realpath(entity["mount-point"]) == mount
           for entity in image.get("system-entities", [])):
        raise SystemExit(0)
raise SystemExit(1)
' "$STAGE" "$MOUNT"
}

cleanup() {
    local status=$?
    trap - EXIT INT TERM HUP
    set +e
    finch_finalize_cleanup "$status" "$STAGE_DIR" "$STAGE" "$MOUNT" \
        "$IMAGE" "$BACKUP" "$MOUNTED" "$REPLACED" "$COMMITTED" "$PRESERVE_STAGE"
}
source "${SCRIPT_DIR}/finalize-system-accounts-cleanup.sh"
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

sha256() {
    /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

file_metadata() {
    /usr/bin/python3 -c 'import os, stat, sys; s=os.stat(sys.argv[1], follow_symlinks=False); print(f"{s.st_uid}:{s.st_gid}:{stat.S_IMODE(s.st_mode):o}")' "$1"
}

ORIGINAL_HASH="$(sha256 "$IMAGE")" || die "cannot hash the original ramdisk"
ORIGINAL_META="$(file_metadata "$IMAGE")" || die "cannot read original image metadata"
STAGE_DIR="$(/usr/bin/mktemp -d "${VM_DIR}/.accounts-finalize.XXXXXX")" ||
    die "cannot create a private staging directory beside the ramdisk"
STAGE="${STAGE_DIR}/ramdisk.dmg"
MOUNT="${STAGE_DIR}/mount"
BACKUP="${STAGE_DIR}/original-ramdisk.dmg"
/bin/mkdir "$MOUNT"
/usr/bin/ditto "$IMAGE" "$STAGE" || die "cannot make the staging copy"
[[ "$(sha256 "$STAGE")" == "$ORIGINAL_HASH" ]] || die "the staging copy does not match the original"
[[ "$(file_metadata "$STAGE")" == "$ORIGINAL_META" ]] ||
    die "the staging copy did not keep the original file owner and mode"

# The account helper checks that the mounted filesystem honors file owners.
MOUNTED=1
/usr/bin/hdiutil attach -plist -owners on -mountpoint "$MOUNT" -nobrowse -noautoopen "$STAGE" >/dev/null ||
    die "cannot attach the staging ramdisk with ownership enabled"
DEVICE="$(mounted_device)" || die "the staging image did not mount at the requested path"
[[ -n "$DEVICE" ]] || die "hdiutil did not report a device for the staging mount"
staging_mount_matches || die "the staging image is attached at an unexpected mount point"
[[ -d "${MOUNT}/private/etc" && ! -L "${MOUNT}/private" && ! -L "${MOUNT}/private/etc" ]] ||
    die "the staging ramdisk has no safe private/etc directory"

"$HELPER" --normalize-staged "${MOUNT}/private/etc" || die "cannot set staged account file ownership"
"$HELPER" --template "$TEMPLATE" --target "${MOUNT}/private/etc" ||
    die "cannot merge the release _notifyd account into the staging image"
"$HELPER" --verify-staged --template "$TEMPLATE" --target "${MOUNT}/private/etc" ||
    die "the staged account files did not pass verification"
/bin/sync
/usr/bin/hdiutil detach "$DEVICE" >/dev/null || die "cannot detach the staging ramdisk safely"
if REMAINING_DEVICE="$(mounted_device)"; then
    die "the staging ramdisk is still attached after detach"
else
    DETACH_CHECK=$?
    [[ "$DETACH_CHECK" == 1 ]] || die "cannot confirm the staging ramdisk detached"
fi
MOUNTED=0

[[ "$(sha256 "$IMAGE")" == "$ORIGINAL_HASH" ]] ||
    die "the original ramdisk changed while the staging copy was being prepared"
STAGE_HASH="$(sha256 "$STAGE")" || die "cannot hash the finalized staging ramdisk"
[[ "$(file_metadata "$STAGE")" == "$ORIGINAL_META" ]] ||
    die "the finalized image no longer has the original file owner and mode"
/bin/ln "$IMAGE" "$BACKUP" || die "cannot keep a rollback link to the original ramdisk"
REPLACED=1
/bin/mv -f "$STAGE" "$IMAGE" || die "cannot atomically replace the ramdisk"
[[ "$(sha256 "$IMAGE")" == "$STAGE_HASH" ]] || die "the installed ramdisk hash does not match the verified copy"
[[ "$(file_metadata "$IMAGE")" == "$ORIGINAL_META" ]] ||
    die "the installed ramdisk did not keep the original file owner and mode"

COMMITTED=1
REPLACED=0
/bin/rm -f "$BACKUP"
echo "Finalized build/vm/ramdisk.dmg with root:wheel account files."
echo "Old SHA-256: $ORIGINAL_HASH"
echo "New SHA-256: $STAGE_HASH"
echo "The trust cache was not changed."
