#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# OpenScripting.framework: Finch's AppleScript (ASValues, ASParser, ASInterpreter) and the OSA
# calls over it (OSA.m), inside Carbon as Apple's is (Carbon re-exports it); and osascript.
#   userland/OpenScripting/build.sh -> build/root/.../Carbon.framework/Versions/A/Frameworks/OpenScripting.framework
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/OpenScripting"
CARBON=/System/Library/Frameworks/Carbon.framework/Versions/A
CFLAGS="-I${HERE}" OBJC_ARC=1 "${FINCH_ROOT}/tools/build-small-framework.sh" \
    "${CARBON}/Frameworks/OpenScripting.framework/Versions/A/OpenScripting" 1810 1 com.apple.openscripting 1.7 \
    "${HERE}/ASValues.m" "${HERE}/ASParser.m" "${HERE}/ASInterpreter.m" "${HERE}/OSA.m" \
    -- -Wl,-umbrella,Carbon -framework Foundation -framework CoreFoundation -framework CoreServices -framework ApplicationServices

# osascript
mkdir -p "${FINCH_ROOT}/build/root/usr/bin"
xcrun -sdk macosx clang -arch arm64e -mmacosx-version-min=26.0 -O2 -Wall -Wextra -Werror -Wno-unused-parameter \
    -Wno-deprecated-declarations -fobjc-arc -o "${FINCH_ROOT}/build/root/usr/bin/osascript" "${HERE}/osascript.m" \
    -framework Foundation -framework Carbon
codesign -f -s - -i com.apple.osascript "${FINCH_ROOT}/build/root/usr/bin/osascript"
echo "==> installed build/root/usr/bin/osascript"
