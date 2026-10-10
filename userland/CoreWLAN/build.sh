#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# CoreWLAN.framework: Finch's. No Wi-Fi interface until there's a driver (CoreWLAN.m);
# CWConstants.m has Apple's values.
#   userland/CoreWLAN/build.sh -> build/root/System/Library/Frameworks/CoreWLAN.framework
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/CoreWLAN"
OBJC_ARC=1 CFLAGS="-Wno-incomplete-implementation -Wno-objc-designated-initializers" "${FINCH_ROOT}/tools/build-small-framework.sh" \
    /System/Library/Frameworks/CoreWLAN.framework/Versions/A/CoreWLAN 1 1 com.apple.framework.CoreWLAN 16.0 \
    "${HERE}/CWConstants.m" "${HERE}/CoreWLAN.m" -- -framework Foundation -framework Security
