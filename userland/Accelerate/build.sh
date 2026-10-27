#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Finch's Accelerate, laid out as Apple's: the Accelerate umbrella re-exports vecLib and
# vImage, and vecLib re-exports its libraries (libvDSP, libvMisc, libBLAS, libLAPACK).
# Each library exports what Apple's .tbd lists and Finch defines (tbd-exports.py).
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
SDK_FW="${SDKROOT}/System/Library/Frameworks/Accelerate.framework/Versions/A/Frameworks"
CC="$(xcrun -f clang)"
PREFIX=/System/Library/Frameworks/Accelerate.framework/Versions/A
VECLIB="${PREFIX}/Frameworks/vecLib.framework/Versions/A"
VIMAGE="${PREFIX}/Frameworks/vImage.framework/Versions/A"
log() { echo "==> $*"; }

[[ -f "${FWS}/CoreGraphics.framework/Versions/A/CoreGraphics" ]] || {
    echo "build CoreGraphics first: userland/CoreGraphics/build.sh" >&2
    exit 1
}

CFLAGS=(-arch arm64e -mmacosx-version-min=26.0 -isysroot "${SDKROOT}" -O2 -g -fno-common -fblocks
    -std=c17 -Wall -Wextra -Werror -Wno-unused-parameter -Wno-nonnull -Wno-pointer-bool-conversion
    -Wno-deprecated-declarations)
LDFLAGS=(-arch arm64e -mmacosx-version-min=26.0 -isysroot "${SDKROOT}" -dynamiclib -Wl,-dead_strip)

rm -rf "${OBJ}"
mkdir -p "${OBJ}" "${ROOT}${VECLIB}" "${ROOT}${VIMAGE}"

# compile NAME SOURCE...: objects into build/obj/Accelerate/NAME
compile() {
    local name="$1"
    shift
    mkdir -p "${OBJ}/${name}"
    for source in "$@"; do
        "${CC}" "${CFLAGS[@]}" -c "${source}" -o "${OBJ}/${name}/$(basename "${source%.c}").o"
    done
}

# library INSTALL TBD CURRENT OBJECT_DIR [LINK_FLAGS...]
library() {
    local install="$1" tbd="$2" current="$3" objects="$4"
    shift 4
    local name
    name="$(basename "${install}")"
    log "linking ${name}"
    "${HERE}/tbd-exports.py" "${tbd}" "${objects}"/*.o > "${OBJ}/${name}.exports"
    "${CC}" "${LDFLAGS[@]}" -install_name "${install}" -current_version "${current}" -compatibility_version 1 \
        "${objects}"/*.o -o "${ROOT}${install}" -Wl,-exported_symbols_list,"${OBJ}/${name}.exports" "$@" -lm
    codesign -f -s - "${ROOT}${install}" 2>/dev/null
}

log "compiling vecLib's libraries and vImage"
compile vDSP "${HERE}"/vDSP/*.c
compile vMisc "${HERE}"/vMisc/*.c
"${HERE}/BLAS/gen-abi.py" "${SDK_FW}/vecLib.framework/Versions/A/Headers" \
    "${SDK_FW}/vecLib.framework/Versions/A/libBLAS.tbd" > "${OBJ}/blas-abi.c"
compile BLAS "${HERE}/BLAS/blas.c" "${OBJ}/blas-abi.c"
compile LAPACK "${HERE}"/LAPACK/*.c
compile vImage "${HERE}"/vImage/*.c

library "${VECLIB}/libvDSP.dylib" "${SDK_FW}/vecLib.framework/Versions/A/libvDSP.tbd" 1126.100.7 "${OBJ}/vDSP"
library "${VECLIB}/libvMisc.dylib" "${SDK_FW}/vecLib.framework/Versions/A/libvMisc.tbd" 1126.100.7 "${OBJ}/vMisc"
library "${VECLIB}/libBLAS.dylib" "${SDK_FW}/vecLib.framework/Versions/A/libBLAS.tbd" 1126.100.7 "${OBJ}/BLAS"
library "${VECLIB}/libLAPACK.dylib" "${SDK_FW}/vecLib.framework/Versions/A/libLAPACK.tbd" 1126.100.7 "${OBJ}/LAPACK" \
    "${ROOT}${VECLIB}/libBLAS.dylib"

# umbrella NAME INSTALL CURRENT BUNDLE_ID SHORT REEXPORT...
umbrella() {
    local name="$1" install="$2" current="$3" id="$4" short="$5"
    shift 5
    log "linking ${name}"
    echo "const double ${name}VersionNumber = ${current%%.*}.0;" > "${OBJ}/${name}-version.c"
    "${CC}" "${LDFLAGS[@]}" -install_name "${install}" -current_version "${current}" -compatibility_version 1 \
        "${OBJ}/${name}-version.c" -o "${ROOT}${install}" $(printf -- '-Wl,-reexport_library,%s ' "$@")
    local fw="${ROOT}${install%/Versions/A/*}"
    ln -sfn A "${fw}/Versions/Current"
    ln -sfn "Versions/Current/${name}" "${fw}/${name}"
    "${FINCH_ROOT}/tools/mkframeworkplist.sh" "${fw}" A "${name}" "${id}" "${name}" "${short}" "${current}" English
    codesign -f -s - -i "${id}" "${ROOT}${install}" 2>/dev/null
}

umbrella vecLib "${VECLIB}/vecLib" 1126.100.7 com.apple.Accelerate.vecLib 3.11 \
    "${ROOT}${VECLIB}/libvMisc.dylib" "${ROOT}${VECLIB}/libvDSP.dylib" "${ROOT}${VECLIB}/libBLAS.dylib" \
    "${ROOT}${VECLIB}/libLAPACK.dylib"

log "linking vImage"
"${HERE}/tbd-exports.py" "${SDK_FW}/vImage.framework/Versions/A/vImage.tbd" "${OBJ}/vImage"/*.o > "${OBJ}/vImage.exports"
"${CC}" "${LDFLAGS[@]}" -install_name "${VIMAGE}/vImage" -current_version 632.100.6 -compatibility_version 1 \
    "${OBJ}/vImage"/*.o -o "${ROOT}${VIMAGE}/vImage" -Wl,-exported_symbols_list,"${OBJ}/vImage.exports" \
    "${ROOT}${VECLIB}/libvMisc.dylib" -F"${FWS}" -framework CoreGraphics -framework CoreFoundation -lm
ln -sfn A "${ROOT}${VIMAGE%/A}/Current"
ln -sfn Versions/Current/vImage "${ROOT}${VIMAGE%/Versions/A}/vImage"
"${FINCH_ROOT}/tools/mkframeworkplist.sh" "${ROOT}${VIMAGE%/Versions/A}" A vImage com.apple.Accelerate.vImage \
    vImage 2.1 632.100.6 English
codesign -f -s - -i com.apple.Accelerate.vImage "${ROOT}${VIMAGE}/vImage" 2>/dev/null

umbrella Accelerate "${PREFIX}/Accelerate" 4 com.apple.Accelerate 1.11 "${ROOT}${VIMAGE}/vImage" "${ROOT}${VECLIB}/vecLib"
ln -sfn Versions/Current/Frameworks "${FW}/Frameworks"
log "installed ${FW#"${FINCH_ROOT}/"}"
