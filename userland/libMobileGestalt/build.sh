#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# libMobileGestalt.dylib: Finch's (MobileGestalt.c).
#   userland/libMobileGestalt/build.sh -> build/root/usr/lib/libMobileGestalt.dylib
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/libMobileGestalt"
ROOT="${FINCH_ROOT}/build/root"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
mkdir -p "${ROOT}/usr/lib"
OBJ="${FINCH_ROOT}/build/obj/libMobileGestalt"
mkdir -p "${OBJ}"
# (compiled against the SDK's headers, linked against Finch's frameworks)
xcrun clang -arch arm64e -mmacosx-version-min=26.0 -isysroot "${SDKROOT}" -Os -g -Wall -Wextra -Werror -Wno-unused-parameter \
    -fvisibility=hidden -c "${HERE}/MobileGestalt.c" -o "${OBJ}/MobileGestalt.o"
xcrun clang -arch arm64e -mmacosx-version-min=26.0 -isysroot "${SDKROOT}" -dynamiclib -install_name /usr/lib/libMobileGestalt.dylib \
    -current_version 1 -compatibility_version 1 "${OBJ}/MobileGestalt.o" -o "${ROOT}/usr/lib/libMobileGestalt.dylib" \
    -F"${ROOT}/System/Library/Frameworks" -framework CoreFoundation -framework IOKit
codesign -f -s - "${ROOT}/usr/lib/libMobileGestalt.dylib" 2>/dev/null
echo "==> installed build/root/usr/lib/libMobileGestalt.dylib"
