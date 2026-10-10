#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# DiskArbitration.framework and diskarbitrationd from Apple's DiskArbitration (pinned in
# userland/projects.txt): the client library and the daemon that watches disks appear
# and go, probes and mounts their volumes, and arbitrates mounts, unmounts and ejects.
#
# Headers come from open sources: the SDK's, IOKitUser's (as userland/IOKit/build.sh
# assembles them), xnu's private ones, and Finch's (userland/DiskArbitration/include).
#
#   userland/DiskArbitration/build.sh -> build/root/System/Library/Frameworks/DiskArbitration.framework
#                                        build/root/usr/libexec/diskarbitrationd
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/DiskArbitration"
SRC="${FINCH_ROOT}/build/src/DiskArbitration"
OBJ="${FINCH_ROOT}/build/obj/DiskArbitration"
ROOT="${FINCH_ROOT}/build/root"
FW="${ROOT}/System/Library/Frameworks/DiskArbitration.framework"
SDK="${FINCH_ROOT}/build/sdk"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
IOKIT_H="${FINCH_ROOT}/build/obj/IOKit/hdr"
CC="$(xcrun -f clang)"
MIG="$(xcrun -f mig)"
log() { echo "==> $*"; }

[[ -d "${SRC}" ]] || { echo "missing DiskArbitration (tools/fetch-src.sh DiskArbitration)" >&2; exit 1; }
[[ -d "${IOKIT_H}" ]] || { echo "build IOKit first (userland/IOKit/build.sh)" >&2; exit 1; }

for p in "${HERE}"/patches/*.patch; do
    [[ -e "$p" ]] || continue
    git -C "${SRC}" apply -R --check "$p" 2>/dev/null || { log "applying $(basename "$p")"; git -C "${SRC}" apply "$p"; }
done

log "assembling headers"
H="${OBJ}/hdr"
rm -rf "${H}" && mkdir -p "${H}/DiskArbitration" "${OBJ}/gen"
cp "${SRC}"/DiskArbitration/*.h "${H}/DiskArbitration/"
rsync -a "${HERE}/include/" "${H}/"

log "generating MIG interfaces"
"${MIG}" -arch arm64e -isysroot "${SDKROOT}" -I"${SRC}/diskarbitrationd" \
    -header "${OBJ}/gen/DAServer.h" -user "${OBJ}/gen/DAServerUser.c" -server /dev/null \
    "${SRC}/DiskArbitration/DAServer.defs"

CFLAGS=(-arch arm64e -mmacosx-version-min=26.0 -isysroot "${SDKROOT}" -Os -g -fblocks
    -I"${OBJ}/gen" -I"${H}" -I"${SRC}/DiskArbitration" -I"${SRC}/diskarbitrationd" -I"${IOKIT_H}"
    -I"${SDK}/include" -idirafter "${SDK}/override" -idirafter "${SDK}/availability"
    -D__APPLE_API_PRIVATE -DPRIVATE -Wno-deprecated-declarations
    -Wno-error=int-conversion)   # Apple's code passes NULL for integers (same width)

log "compiling the framework"
mkdir -p "${OBJ}/o"
failed=0
for s in "${SRC}"/DiskArbitration/{DADisk,DADissenter,DAInternal,DASession,DiskArbitration,DiskArbitrationPrivate}.c "${OBJ}/gen/DAServerUser.c"; do
    o="${OBJ}/o/$(basename "${s%.*}").o"
    "${CC}" "${CFLAGS[@]}" -c "$s" -o "$o" 2> "$o.log" \
        || { echo "  failed: $(basename "$s") ($(grep -c 'error:' "$o.log") errors, ${o#"${FINCH_ROOT}/"}.log)"; failed=1; }
done
[[ ${failed} == 0 ]] || { echo "compile failed" >&2; exit 1; }

log "linking the framework"
mkdir -p "${FW}/Versions/A/Headers" "${FW}/Versions/A/Resources"
"${CC}" -arch arm64e -mmacosx-version-min=26.0 -isysroot "${SDKROOT}" -dynamiclib \
    -install_name /System/Library/Frameworks/DiskArbitration.framework/Versions/A/DiskArbitration \
    -current_version 1 -compatibility_version 1 \
    "${OBJ}"/o/*.o -o "${FW}/Versions/A/DiskArbitration" \
    -F"${ROOT}/System/Library/Frameworks" -framework CoreFoundation -framework IOKit -framework Security -lbsm -lSystem
ln -sfn A "${FW}/Versions/Current"
ln -sfn Versions/Current/DiskArbitration "${FW}/DiskArbitration"
"${FINCH_ROOT}/tools/mkframeworkplist.sh" "${FW}" A DiskArbitration com.apple.DiskArbitration "Disk Arbitration" 2.7 "" English
codesign -f -s - -i com.apple.DiskArbitration "${FW}/Versions/A/DiskArbitration" 2>/dev/null
log "installed ${FW#"${FINCH_ROOT}/"}"
