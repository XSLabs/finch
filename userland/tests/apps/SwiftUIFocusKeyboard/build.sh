#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Build a focused keyboard and focus test app against Apple's SDK for Finch.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
FINCH_ROOT="$(cd "${HERE}/../../../.." && pwd)"
APP="${FINCH_ROOT}/build/userland/apps/SwiftUIFocusKeyboard.app"
rm -rf "${APP}" && mkdir -p "${APP}/Contents/MacOS"
xcrun -sdk macosx swiftc -target arm64e-apple-macos26.0 -O -parse-as-library \
    -Xfrontend -disable-autolink-library -Xfrontend swiftMetal \
    -Xfrontend -disable-autolink-library -Xfrontend swiftSpatial \
    -o "${APP}/Contents/MacOS/SwiftUIFocusKeyboard" "${HERE}/main.swift"
cp "${HERE}/Info.plist" "${APP}/Contents/Info.plist"
printf 'APPL????' > "${APP}/Contents/PkgInfo"
codesign -f -s - --entitlements "${HERE}/../debug.entitlements" "${APP}" 2>/dev/null
echo "built ${APP#"${FINCH_ROOT}/"}"
