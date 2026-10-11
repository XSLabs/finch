#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Build Apple's published FAT helpers and install the native msdos.fs bundle.
set -euo pipefail

FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="${SRC:-${FINCH_ROOT}/build/src/msdosfs}"
OBJ="${OBJ:-${FINCH_ROOT}/build/obj/msdosfs}"
STAGE="${STAGE:-${FINCH_ROOT}/build/root}"
SDKROOT="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
SDK="${FINCH_ROOT}/build/sdk"
PATCH_DIR="${FINCH_ROOT}/userland/patches/msdosfs"
OVERLAY_ROOT="${OBJ}/framework-overlay"
PUBLIC_OVERLAY="${OVERLAY_ROOT}/System/Library/Frameworks"
CONFIG="${OBJ}/finch.xcconfig"
EXPECTED_SOURCE="8aac438d87dc696cf424f0c0f46e874e7d85b9f0"

[[ -d "${SRC}/.git" ]] || {
    echo "error: pinned msdosfs source is missing: ${SRC}" >&2
    exit 1
}
[[ "$(git -C "${SRC}" rev-parse HEAD)" == "${EXPECTED_SOURCE}" ]] || {
    echo "error: msdosfs source is not at the pinned 788.100.31 revision" >&2
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
        echo "error: msdosfs patch does not apply: ${patch}" >&2
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
// Finch builds these tools with Finch's CoreFoundation and IOKit.
FRAMEWORK_SEARCH_PATHS = ${PUBLIC_OVERLAY} ${SDKROOT}/System/Library/Frameworks
SYSTEM_FRAMEWORK_SEARCH_PATHS = ${PUBLIC_OVERLAY} ${SDKROOT}/System/Library/Frameworks
HEADER_SEARCH_PATHS = \$(inherited)
LIBRARY_SEARCH_PATHS = \$(inherited) ${FINCH_ROOT}/build/userland/lib ${FINCH_ROOT}/build/root/usr/lib
OTHER_CFLAGS = \$(inherited) -Wno-error -idirafter ${SDK}/include -idirafter ${SDK}/override -idirafter ${SDK}/availability
OTHER_LDFLAGS = -Wl,-dead_strip_dylibs -framework CoreFoundation -framework IOKit -lutil
ENABLE_USER_SCRIPT_SANDBOXING = NO
EOF

for scheme in msdos.fs msdos.util mount_msdos newfs_msdos fsck_msdos; do
    if ! xcodebuild install -project "${SRC}/msdosfs.xcodeproj" -scheme "${scheme}" \
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

BUNDLE="${STAGE}/System/Library/Filesystems/msdos.fs"
RESOURCE_DIR="${BUNDLE}/Contents/Resources"
LICENSE_DIR="${STAGE}/usr/share/finch/licenses/msdosfs"
[[ -f "${BUNDLE}/Contents/Info.plist" ]] || {
    echo "error: msdos.fs Info.plist was not installed" >&2
    exit 1
}
for tool in msdos.util mount_msdos newfs_msdos fsck_msdos; do
    [[ -x "${RESOURCE_DIR}/${tool}" ]] || {
        echo "error: msdos.fs is missing ${tool}" >&2
        exit 1
    }
    codesign -f -s - "${RESOURCE_DIR}/${tool}" 2>/dev/null
    codesign --verify --strict "${RESOURCE_DIR}/${tool}"
    lipo "${RESOURCE_DIR}/${tool}" -verify_arch arm64e
done
mkdir -p "${LICENSE_DIR}"
install -m 0644 "${SRC}/APPLE_LICENSE" "${LICENSE_DIR}/APPLE_LICENSE"
install -m 0644 "${SRC}/APPLE_LICENSE" "${RESOURCE_DIR}/APPLE_LICENSE"
python3 -I "${FINCH_ROOT}/tools/collect-notices.py" \
    "Apple msdosfs (788.100.31)" "${LICENSE_DIR}/SOURCE-NOTICES.txt" \
    "${SRC}/msdos_util.tproj/dosutil.c" \
    "${SRC}/mount_msdos.tproj/mount_msdos.c" \
    "${SRC}/newfs_msdos.tproj/newfs_msdos.c" \
    "${SRC}/lib_newfs_msdos/lib_newfs_msdos.c" \
    "${SRC}/lib_newfs_msdos/format.c" \
    "${SRC}/fsck_msdos.tproj/main.c" \
    "${SRC}/lib_fsck_msdos/boot.c" \
    "${SRC}/lib_fsck_msdos/check.c" \
    "${SRC}/lib_fsck_msdos/dir.c" \
    "${SRC}/lib_fsck_msdos/fat.c" \
    "${SRC}/lib_fsck_msdos/fsutil.c" \
    "${SRC}/lib_fsck_msdos/lib_fsck_msdos.c"
plutil -lint "${BUNDLE}/Contents/Info.plist" >/dev/null
for tool in mount_msdos newfs_msdos fsck_msdos; do
    link="${STAGE}/sbin/${tool}"
    target="/System/Library/Filesystems/msdos.fs/Contents/Resources/${tool}"
    [[ -L "${link}" && "$(readlink "${link}")" == "${target}" ]] || {
        echo "error: missing native /sbin/${tool} link" >&2
        exit 1
    }
done
