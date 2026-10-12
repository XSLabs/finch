#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Build Apple's basic mount and fsck dispatchers for Finch.
set -euo pipefail

FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="${SRC:-${FINCH_ROOT}/build/src/diskdev_cmds}"
OBJ="${OBJ:-${FINCH_ROOT}/build/obj/diskdev_cmds}"
STAGE="${STAGE:-${FINCH_ROOT}/build/root}"
SDKROOT="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
SDK="${FINCH_ROOT}/build/sdk"
PATCH_DIR="${FINCH_ROOT}/userland/patches/diskdev_cmds"
OVERLAY_ROOT="${OBJ}/framework-overlay"
PUBLIC_OVERLAY="${OVERLAY_ROOT}/System/Library/Frameworks"
CONFIG="${OBJ}/finch.xcconfig"
EXPECTED_SOURCE="cc6766b9d585a43609a24e0b9e56cf9665e63198"

[[ -d "${SRC}/.git" ]] || {
    echo "error: pinned diskdev_cmds source is missing: ${SRC}" >&2
    exit 1
}
[[ "$(git -C "${SRC}" rev-parse HEAD)" == "${EXPECTED_SOURCE}" ]] || {
    echo "error: diskdev_cmds source is not at the pinned 757 revision" >&2
    exit 1
}
[[ -d "${SDKROOT}/System/Library/Frameworks/CoreFoundation.framework/Headers" ]] || {
    echo "error: public macOS SDK headers are missing from ${SDKROOT}" >&2
    exit 1
}

mkdir -p "${OBJ}" "${STAGE}"
for patch in "${PATCH_DIR}"/*.patch; do
    [[ -f "${patch}" ]] || continue
    if git -C "${SRC}" apply --check "${patch}" 2>/dev/null; then
        git -C "${SRC}" apply "${patch}"
    elif ! git -C "${SRC}" apply --check --reverse "${patch}" 2>/dev/null; then
        echo "error: diskdev_cmds patch does not apply: ${patch}" >&2
        exit 1
    fi
done

if [[ -L "${OVERLAY_ROOT}" ]]; then
    echo "error: refusing to replace a framework overlay symlink: ${OVERLAY_ROOT}" >&2
    exit 1
fi
rm -rf "${OVERLAY_ROOT}"
for framework in CoreFoundation IOKit; do
    finch_framework="${FINCH_ROOT}/build/root/System/Library/Frameworks/${framework}.framework"
    sdk_framework="${SDKROOT}/System/Library/Frameworks/${framework}.framework"
    wrapper="${PUBLIC_OVERLAY}/${framework}.framework"
    [[ -e "${finch_framework}/${framework}" ]] || {
        echo "error: Finch ${framework} framework is missing; build it first" >&2
        exit 1
    }
    [[ -d "${sdk_framework}/Headers" ]] || {
        echo "error: public ${framework} headers are missing from ${SDKROOT}" >&2
        exit 1
    }
    mkdir -p "${wrapper}"
    ln -s "${finch_framework}/${framework}" "${wrapper}/${framework}"
    ln -s "${sdk_framework}/Headers" "${wrapper}/Headers"
    if [[ -d "${sdk_framework}/Modules" ]]; then
        ln -s "${sdk_framework}/Modules" "${wrapper}/Modules"
    fi
done

cat > "${CONFIG}" <<EOF
// Finch uses its own CoreFoundation and IOKit and leaves Apple-only features off.
FRAMEWORK_SEARCH_PATHS = ${PUBLIC_OVERLAY} ${SDKROOT}/System/Library/Frameworks
SYSTEM_FRAMEWORK_SEARCH_PATHS = ${PUBLIC_OVERLAY} ${SDKROOT}/System/Library/Frameworks
HEADER_SEARCH_PATHS = \$(inherited)
LIBRARY_SEARCH_PATHS = \$(inherited) ${FINCH_ROOT}/build/userland/lib ${FINCH_ROOT}/build/root/usr/lib
GCC_PREPROCESSOR_DEFINITIONS = \$(inherited) FINCH_NO_APFS FINCH_NO_FSKIT
OTHER_CFLAGS = \$(inherited) -Wno-error -idirafter ${SDK}/include -idirafter ${SDK}/override -idirafter ${SDK}/availability
OTHER_LDFLAGS = -Wl,-dead_strip_dylibs -framework CoreFoundation -framework IOKit -lutil
ENABLE_USER_SCRIPT_SANDBOXING = NO
EOF

# (an earlier install leaves its tools read-only, which the linker can't overwrite)
for tool in mount fsck; do
    [[ -e "${STAGE}/sbin/${tool}" ]] && chmod u+w "${STAGE}/sbin/${tool}"
done

for scheme in mount fsck; do
    if ! xcodebuild install -project "${SRC}/diskdev_cmds.xcodeproj" -scheme "${scheme}" \
        -configuration Release -sdk macosx -xcconfig "${CONFIG}" \
        -derivedDataPath "${OBJ}/derived" ARCHS=arm64e ONLY_ACTIVE_ARCH=NO \
        SDKROOT="${SDKROOT}" DSTROOT="${STAGE}" OBJROOT="${OBJ}/obj" \
        SYMROOT="${OBJ}/sym" SHARED_PRECOMPS_DIR="${OBJ}/precompiled" \
        CODE_SIGNING_ALLOWED=NO GCC_TREAT_WARNINGS_AS_ERRORS=NO \
        > "${OBJ}/${scheme}.log" 2>&1; then
        tail -n 100 "${OBJ}/${scheme}.log" >&2
        exit 1
    fi
done

for tool in mount fsck; do
    binary="${STAGE}/sbin/${tool}"
    [[ -x "${binary}" ]] || {
        echo "error: diskdev_cmds did not install /sbin/${tool}" >&2
        exit 1
    }
    codesign -f -s - "${binary}" 2>/dev/null
    codesign --verify --strict "${binary}"
    lipo "${binary}" -verify_arch arm64e
done

LICENSE_DIR="${STAGE}/usr/share/finch/licenses/diskdev_cmds"
mkdir -p "${LICENSE_DIR}"
install -m 0644 "${SRC}/APPLE_LICENSE" "${LICENSE_DIR}/APPLE_LICENSE"
python3 -I "${FINCH_ROOT}/tools/collect-notices.py" \
    "Apple diskdev_cmds (757)" "${LICENSE_DIR}/SOURCE-NOTICES.txt" \
    "${SRC}/mount.tproj/mount.c" \
    "${SRC}/mount.tproj/mount_tmpfs.c" \
    "${SRC}/mount_flags_dir/mount_flags.c" \
    "${SRC}/fsck.tproj/fsck.c" \
    "${SRC}/edt_fstab/edt_fstab.c" \
    "${SRC}/disklib/dkcksum.c" \
    "${SRC}/disklib/dkdisklabel.c" \
    "${SRC}/disklib/dkopen.c" \
    "${SRC}/disklib/dksecsize.c" \
    "${SRC}/disklib/fskit_support.m" \
    "${SRC}/disklib/preen.c" \
    "${SRC}/disklib/vfslist.c"
