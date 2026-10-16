#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# VideoToolbox.framework: pixel transfer and rotation over Finch's CoreVideo buffers,
# H.264/VP8/VP9/AV1 decoding, and H.264 encoding. The codec sources are pinned in
# userland/third-party-projects.txt; they are built as hidden-symbol static libraries.
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/VideoToolbox"
SRC="${FINCH_ROOT}/build/src"
OBJ="${FINCH_ROOT}/build/obj/VideoToolboxDeps"
ROOT="${FINCH_ROOT}/build/root"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
CC="$(xcrun -f clang)"
CXX="$(xcrun -f clang++)"
FINCH_BUILD_JOBS="${FINCH_BUILD_JOBS:-$(sysctl -n hw.ncpu)}"
log() { echo "==> $*"; }

for project in openh264 libvpx dav1d; do
    "${FINCH_ROOT}/tools/fetch-src.sh" "${project}"
done

OPENH264="${SRC}/openh264"
VPX="${SRC}/libvpx"
DAV1D="${SRC}/dav1d"
[[ -f "${OPENH264}/codec/api/wels/codec_api.h" && -f "${VPX}/vpx/vpx_decoder.h" && -f "${DAV1D}/include/dav1d/dav1d.h" ]] || {
    echo "VideoToolbox codec sources are missing; run tools/fetch-src.sh openh264 libvpx dav1d" >&2
    exit 1
}

ARCH_FLAGS="-arch arm64e -mmacosx-version-min=26.0 -isysroot ${SDKROOT}"
HIDDEN_FLAGS="${ARCH_FLAGS} -O2 -DNDEBUG -fvisibility=hidden"

log "building OpenH264 v2.6.0 as a static library"
make -C "${OPENH264}" clean >/dev/null
make -C "${OPENH264}" -j"${FINCH_BUILD_JOBS}" ARCH=arm64 USE_ASM=No \
    CC="${CC}" CXX="${CXX}" AR=ar V=No \
    CFLAGS="${HIDDEN_FLAGS} -fPIC -MMD -MP -DGENERATED_VERSION_HEADER" \
    CXXFLAGS="${HIDDEN_FLAGS} -fPIC -stdlib=libc++ -std=c++17" \
    libopenh264.a

VPX_OBJ="${OBJ}/libvpx"
log "building libvpx v1.17.0 as a VP8 and VP9 decoder"
rm -rf "${VPX_OBJ}"
mkdir -p "${VPX_OBJ}"
VPX_FLAGS="-mmacosx-version-min=26.0 -isysroot ${SDKROOT} -O2 -DNDEBUG -fvisibility=hidden"
(
    cd "${VPX_OBJ}"
    CC="${CC}" AR=ar LD="${CC}" "${VPX}/configure" --target=arm64-darwin25-gcc --disable-examples --disable-tools \
        --disable-docs --disable-unit-tests --disable-shared --enable-static \
        --enable-vp8-decoder --enable-vp9-decoder --disable-vp8-encoder --disable-vp9-encoder \
        --extra-cflags="${VPX_FLAGS}"
    # libvpx's macOS target hard-codes arm64, while Finch's frameworks use arm64e.
    # Adjust only this generated build file so every dependency object links to Finch.
    python3 - "${VPX_OBJ}/libs-arm64-darwin25-gcc.mk" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text()
if "-arch arm64 " not in text:
    raise SystemExit("could not find libvpx's generated arm64 compiler flags")
path.write_text(text.replace("-arch arm64 ", "-arch arm64e "))
PY
    make -j"${FINCH_BUILD_JOBS}" libvpx.a
)

DAV1D_OBJ="${OBJ}/dav1d"
log "building dav1d 1.5.4 as a static library"
rm -rf "${DAV1D_OBJ}"
CC="${CC}" CFLAGS="${HIDDEN_FLAGS}" meson setup "${DAV1D_OBJ}" "${DAV1D}" \
    --buildtype=release --default-library=static -Denable_asm=false -Denable_tools=false \
    -Denable_examples=false -Denable_tests=false -Dbitdepths=8,16 -Dlogging=false
meson compile -C "${DAV1D_OBJ}" -j "${FINCH_BUILD_JOBS}"

OPENH264_LIB="${OPENH264}/libopenh264.a"
VPX_LIB="${VPX_OBJ}/libvpx.a"
DAV1D_LIB="$(find "${DAV1D_OBJ}" -name libdav1d.a -type f -print -quit)"
[[ -s "${OPENH264_LIB}" && -s "${VPX_LIB}" && -n "${DAV1D_LIB}" && -s "${DAV1D_LIB}" ]] || {
    echo "a static codec library is missing after the build" >&2
    exit 1
}

log "building VideoToolbox.framework"
CFLAGS="-fvisibility=hidden -I${OPENH264}/codec/api/wels -I${VPX} -I${VPX_OBJ} -I${DAV1D}/include" \
    "${FINCH_ROOT}/tools/build-small-framework.sh" \
    /System/Library/Frameworks/VideoToolbox.framework/Versions/A/VideoToolbox \
    1.0.0 1.0.0 com.apple.VideoToolbox 1.0.0 \
    "${HERE}/VTConstants.c" "${HERE}/VTSession.c" "${HERE}/VTPixelSessions.c" \
    "${HERE}/VTCodecs.c" "${HERE}/VTDecompression.c" "${HERE}/VTCompression.c" "${HERE}/VTH264.cpp" \
    -- "${OPENH264_LIB}" "${VPX_LIB}" "${DAV1D_LIB}" -lc++ -lm \
    -framework CoreFoundation -framework CoreVideo -framework CoreMedia \
    -Wl,-exported_symbols_list,"${HERE}/exports.txt"

for spec in "openh264:LICENSE" "openh264:PATENTS" "libvpx:LICENSE" "libvpx:PATENTS" "dav1d:COPYING"; do
    project="${spec%%:*}"
    sourceFile="${spec#*:}"
    [[ -f "${SRC}/${project}/${sourceFile}" ]] || continue
    noticeDir="${ROOT}/usr/share/finch/licenses/${project}"
    mkdir -p "${noticeDir}"
    cp "${SRC}/${project}/${sourceFile}" "${noticeDir}/${sourceFile}"
done
log "installed VideoToolbox and codec notices"
