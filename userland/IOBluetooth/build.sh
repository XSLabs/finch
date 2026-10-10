#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# IOBluetooth.framework: Finch's. No host controller until there's a Bluetooth driver
# (IOBluetooth.m); BTConstants.m has Apple's values.
#   userland/IOBluetooth/build.sh -> build/root/System/Library/Frameworks/IOBluetooth.framework
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/IOBluetooth"
OBJC_ARC=1 CFLAGS="-Wno-incomplete-implementation -Wno-objc-designated-initializers -Wno-deprecated-implementations" \
"${FINCH_ROOT}/tools/build-small-framework.sh" \
    /System/Library/Frameworks/IOBluetooth.framework/Versions/A/IOBluetooth 1 1 com.apple.Bluetooth 1.0 \
    "${HERE}/BTConstants.m" "${HERE}/IOBluetooth.m" -- -framework Foundation -framework IOKit
