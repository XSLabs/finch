#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# CoreLocation.framework: Finch's. Location Services off (no positioning yet), with the
# value classes and geodesy in full (CoreLocation.m); CLConstants.m has Apple's values.
#   userland/CoreLocation/build.sh -> build/root/System/Library/Frameworks/CoreLocation.framework
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/CoreLocation"
OBJC_ARC=1 CFLAGS="-Wno-objc-designated-initializers -Wno-incomplete-implementation" "${FINCH_ROOT}/tools/build-small-framework.sh" \
    /System/Library/Frameworks/CoreLocation.framework/Versions/A/CoreLocation 3072.0.46 1 com.apple.corelocation 3072.0.46.3.1 \
    "${HERE}/CLConstants.m" "${HERE}/CoreLocation.m" -- -framework Foundation
