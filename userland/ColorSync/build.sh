#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# ColorSync.framework: Finch's. Profiles (ColorSyncProfile.c) are ICC data: read from
# files or memory, or written here for the named profiles; transforms
# (ColorSyncTransform.c) convert matrix/curve, gray, Lab and XYZ profiles themselves and
# lookup-table profiles through skcms. ColorSyncConstants.c has Apple's constant values.
# Devices and their profiles (ColorSyncDevice.c) are a registry in the preferences.
# The standard profiles are installed in /System/Library/ColorSync/Profiles (write-profiles.c).
#   userland/ColorSync/build.sh -> build/root/System/Library/Frameworks/ColorSync.framework
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/ColorSync"
SKCMS="${FINCH_ROOT}/build/obj/skia/libskcms.a"
[[ -f "${SKCMS}" ]] || { echo "build Skia first (userland/CoreGraphics)" >&2; exit 1; }
CFLAGS="-I${FINCH_ROOT}/build/src/skia/modules/skcms" \
"${FINCH_ROOT}/tools/build-small-framework.sh" \
    /System/Library/Frameworks/ColorSync.framework/Versions/A/ColorSync 3813.3.3 1 com.apple.ColorSync 4.13.0 \
    "${HERE}/ColorSyncConstants.c" "${HERE}/ColorSyncProfile.c" "${HERE}/ColorSyncTransform.c" "${HERE}/ColorSyncDevice.c" \
    -- -framework CoreFoundation -L"$(dirname "${SKCMS}")" -Wl,-hidden-lskcms -lc++

# The installed profiles: the standard ones this ColorSync writes (write-profiles.c).
PROFILES="${FINCH_ROOT}/build/root/System/Library/ColorSync/Profiles"
mkdir -p "${PROFILES}" "${FINCH_ROOT}/build/obj/colorsync"
# (built against the SDK, run against this ColorSync: the install names match)
xcrun clang -O2 "${HERE}/write-profiles.c" -framework ColorSync \
    -framework CoreFoundation -o "${FINCH_ROOT}/build/obj/colorsync/write-profiles"
# (Finch's frameworks reach its standalone libraries, such as OpenDirectory's
# libfinchaccount; the fallback path finds only libraries the host doesn't have)
DYLD_FRAMEWORK_PATH="${FINCH_ROOT}/build/root/System/Library/Frameworks:${FINCH_ROOT}/build/root/System/Library/PrivateFrameworks" \
DYLD_FALLBACK_LIBRARY_PATH="${FINCH_ROOT}/build/root/usr/lib/system:/usr/local/lib:/usr/lib" \
    "${FINCH_ROOT}/build/obj/colorsync/write-profiles" "${PROFILES}"
