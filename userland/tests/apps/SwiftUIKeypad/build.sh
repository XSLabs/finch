#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Build SwiftUIKeypad.app as Xcode would (swiftc against Apple's SDK, an Info.plist), for
# running unmodified on Finch's SwiftUI.
#   userland/tests/apps/SwiftUIKeypad/build.sh -> build/userland/apps/SwiftUIKeypad.app
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
FINCH_ROOT="$(cd "${HERE}/../../../.." && pwd)"
APP="${FINCH_ROOT}/build/userland/apps/SwiftUIKeypad.app"
rm -rf "${APP}" && mkdir -p "${APP}/Contents/MacOS"
# These demos do not use the Metal or Spatial Swift helpers. Avoid linking
# those Apple libraries just because the SDK imports them.
xcrun -sdk macosx swiftc -target arm64e-apple-macos26.0 -O -parse-as-library \
    -Xfrontend -disable-autolink-library -Xfrontend swiftMetal \
    -Xfrontend -disable-autolink-library -Xfrontend swiftSpatial \
    -o "${APP}/Contents/MacOS/SwiftUIKeypad" "${HERE}/main.swift"
cp "${HERE}/Info.plist" "${APP}/Contents/Info.plist"
printf 'APPL????' > "${APP}/Contents/PkgInfo"
codesign -f -s - --entitlements "${HERE}/../debug.entitlements" "${APP}" 2>/dev/null
echo "built ${APP#"${FINCH_ROOT}/"}"
