#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Finch's Accelerate image, with scalar implementations of the vDSP, vForce,
# vImage, BLAS and LAPACK calls apps use today. The public declarations come
# from the macOS SDK; only the small set in exports.txt is linked here.
#
#   userland/Accelerate/build.sh
#     -> build/root/System/Library/Frameworks/Accelerate.framework
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/Accelerate"
OBJ="${FINCH_ROOT}/build/obj/Accelerate"
ROOT="${FINCH_ROOT}/build/root"
FWS="${ROOT}/System/Library/Frameworks"
FW="${FWS}/Accelerate.framework"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
CC="$(xcrun -f clang)"

[[ -f "${FWS}/CoreGraphics.framework/Versions/A/CoreGraphics" ]] || {
    echo "build CoreGraphics first: userland/CoreGraphics/build.sh" >&2
    exit 1
}

CFLAGS=(-arch arm64e -mmacosx-version-min=26.0 -isysroot "${SDKROOT}" -Os -g -fno-common -fblocks
    -std=c17 -Wall -Wextra -Werror -Wno-unused-parameter -Wno-nonnull -Wno-pointer-bool-conversion
    -Wno-deprecated-declarations)

echo "==> compiling Finch's Accelerate calls"
rm -rf "${OBJ}"
mkdir -p "${OBJ}"
for source in "${HERE}"/*.c; do
    "${CC}" "${CFLAGS[@]}" -c "${source}" -o "${OBJ}/$(basename "${source%.c}").o"
done

echo "==> linking Accelerate.framework"
mkdir -p "${FW}/Versions/A"
"${CC}" -arch arm64e -mmacosx-version-min=26.0 -isysroot "${SDKROOT}" -dynamiclib \
    -install_name /System/Library/Frameworks/Accelerate.framework/Versions/A/Accelerate \
    -current_version 4 -compatibility_version 1 \
    "${OBJ}"/*.o -o "${FW}/Versions/A/Accelerate" \
    -Wl,-exported_symbols_list,"${HERE}/exports.txt" -Wl,-dead_strip \
    -F"${FWS}" -framework CoreGraphics -framework CoreFoundation -lm -lSystem
ln -sfn A "${FW}/Versions/Current"
ln -sfn Versions/Current/Accelerate "${FW}/Accelerate"
"${FINCH_ROOT}/tools/mkframeworkplist.sh" "${FW}" A Accelerate \
    com.apple.Accelerate Accelerate 4.0 4 English
codesign -f -s - -i com.apple.Accelerate "${FW}/Versions/A/Accelerate" 2>/dev/null
echo "==> installed ${FW#"${FINCH_ROOT}/"}"
