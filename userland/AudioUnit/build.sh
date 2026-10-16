#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# AudioUnit.framework is a thin compatibility image that re-exports AudioToolbox.
#   userland/AudioUnit/build.sh -> build/root/System/Library/Frameworks/AudioUnit.framework
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
"${FINCH_ROOT}/tools/build-small-framework.sh" \
    /System/Library/Frameworks/AudioUnit.framework/Versions/A/AudioUnit 1.0 1 com.apple.audio.units.AudioUnit 1.14 \
    "${FINCH_ROOT}/userland/AudioUnit/AudioUnit.c" -- -Wl,-reexport_framework,AudioToolbox
plutil -replace CFBundleVersion -string 1.14 \
    "${FINCH_ROOT}/build/root/System/Library/Frameworks/AudioUnit.framework/Versions/A/Resources/Info.plist"
