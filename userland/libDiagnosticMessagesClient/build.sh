#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# libDiagnosticMessagesClient.dylib: Finch's (DiagnosticMessagesClient.c).
#   userland/libDiagnosticMessagesClient/build.sh -> build/root/usr/lib/libDiagnosticMessagesClient.dylib
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/libDiagnosticMessagesClient"
ROOT="${FINCH_ROOT}/build/root"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
mkdir -p "${ROOT}/usr/lib"
OBJ="${FINCH_ROOT}/build/obj/libDiagnosticMessagesClient"
mkdir -p "${OBJ}"
# (ASL is deprecated in the SDK's headers, but it's what these messages are)
xcrun clang -arch arm64e -mmacosx-version-min=26.0 -isysroot "${SDKROOT}" -Os -g -Wall -Wextra -Werror -Wno-unused-parameter -Wno-deprecated-declarations \
    -fvisibility=hidden -c "${HERE}/DiagnosticMessagesClient.c" -o "${OBJ}/DiagnosticMessagesClient.o"
xcrun clang -arch arm64e -mmacosx-version-min=26.0 -isysroot "${SDKROOT}" -dynamiclib -install_name /usr/lib/libDiagnosticMessagesClient.dylib \
    -current_version 1 -compatibility_version 1 "${OBJ}/DiagnosticMessagesClient.o" -o "${ROOT}/usr/lib/libDiagnosticMessagesClient.dylib"
codesign -f -s - "${ROOT}/usr/lib/libDiagnosticMessagesClient.dylib" 2>/dev/null
echo "==> installed build/root/usr/lib/libDiagnosticMessagesClient.dylib"
