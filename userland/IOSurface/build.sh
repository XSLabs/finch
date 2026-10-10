#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# IOSurface.framework: Finch's. Shared pixel buffers over Mach memory objects, laid out as
# Apple's are, passed between processes by port or XPC (IOSurface.m); IOSConstants.m
# has Apple's values.
#   userland/IOSurface/build.sh -> build/root/System/Library/Frameworks/IOSurface.framework
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/IOSurface"
OBJC_ARC=1 CFLAGS="-Wno-incomplete-implementation -Wno-objc-designated-initializers -Wno-deprecated-declarations" \
    "${FINCH_ROOT}/tools/build-small-framework.sh" \
    /System/Library/Frameworks/IOSurface.framework/Versions/A/IOSurface 1.0.0 1 com.apple.iosurface 393.5.7 \
    "${HERE}/IOSConstants.m" "${HERE}/IOSurface.m" -- -framework Foundation -framework CoreFoundation
