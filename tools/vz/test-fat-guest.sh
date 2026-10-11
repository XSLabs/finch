#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Run only inside the existing VZ guest, after mounting the read-only build share.
# Copy this script into build/ first, then pass its guest path to tools/vz/ssh.
# It creates and removes its own guest-local image; it does not test mounting.
set -euo pipefail
[[ "$(/usr/bin/uname -s)" == Darwin && "$(/usr/sbin/sysctl -n hw.model)" == VirtualMac* ]]
[[ "$HOME" == /Users/developer ]]
base="$HOME/finch/root"
tooldir="$base/System/Library/Filesystems/msdos.fs/Contents/Resources"
[[ -x "$tooldir/newfs_msdos" && -x "$tooldir/fsck_msdos" ]]
mkdir -p "$HOME/tmp"
trial=$(mktemp -d "$HOME/tmp/finch-fat-check.XXXXXXXX")
image="$trial/blank.sparseimage"
device=
cleanup() {
    status=$?
    trap - EXIT
    if [[ -n "$device" ]]; then
        if ! /usr/bin/hdiutil detach "$device"; then
            echo "FAIL: could not detach scratch image; retained $trial" >&2
            exit 1
        fi
    fi
    if [[ -f "$image" ]]; then rm "$image"; fi
    echo "Scratch image cleaned; test records: $trial"
    exit "$status"
}
trap cleanup EXIT
/usr/bin/hdiutil create -size 64m -type SPARSE -layout NONE "$image"
/usr/bin/hdiutil attach -nomount -plist "$image" > "$trial/attach.plist"
device=$(/usr/libexec/PlistBuddy -c 'Print :system-entities:0:dev-entry' "$trial/attach.plist")
[[ "$device" =~ ^/dev/disk[0-9]+$ ]]
if /usr/libexec/PlistBuddy -c 'Print :system-entities:1' "$trial/attach.plist" >/dev/null 2>&1; then
    echo 'FAIL: expected one scratch device' >&2; exit 1
fi
/usr/bin/hdiutil info -plist > "$trial/images.plist"
i=0
matched=0
while entry=$(/usr/libexec/PlistBuddy -c "Print :images:$i:image-path" "$trial/images.plist" 2>/dev/null); do
    if [[ "$entry" == "$image" ]]; then
        entryDevice=$(/usr/libexec/PlistBuddy -c "Print :images:$i:system-entities:0:dev-entry" "$trial/images.plist")
        [[ "$entryDevice" == "$device" ]]
        matched=$((matched+1))
    fi
    i=$((i+1))
done
[[ "$matched" == 1 ]]
raw="/dev/r${device#/dev/}"
[[ -c "$raw" && -w "$raw" ]]
if /sbin/mount | /usr/bin/grep -q "^$device on "; then
    echo 'FAIL: scratch device is already mounted' >&2; exit 1
fi
printf 'Verified guest scratch image: %s -> %s\n' "$image" "$raw"
R="$base/System/Library"
FW="$R/Frameworks:$R/PrivateFrameworks:$R/Frameworks/Quartz.framework/Frameworks"
FW="$FW:$R/Frameworks/CoreServices.framework/Versions/A/Frameworks:$R/Frameworks/ApplicationServices.framework/Versions/A/Frameworks:$R/Frameworks/Carbon.framework/Versions/A/Frameworks"
DYLD_FRAMEWORK_PATH="$FW" DYLD_LIBRARY_PATH="$base/usr/lib/swift:$base/usr/lib" DYLD_PRINT_LIBRARIES=1 "$tooldir/newfs_msdos" -F 32 "$raw" > "$trial/format.log" 2>&1
cat "$trial/format.log"
/usr/bin/grep -F "$R/Frameworks/CoreFoundation.framework" "$trial/format.log" >/dev/null
/usr/bin/grep -F "$R/Frameworks/IOKit.framework" "$trial/format.log" >/dev/null
"$tooldir/fsck_msdos" -n "$raw"
echo 'PASS: Finch FAT format and read-only consistency check in the VZ guest'
