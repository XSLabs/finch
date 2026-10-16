#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# SecurityInterface.framework: Finch's certificate, identity, keychain, and
# authorization UI over Finch's AppKit and Security services.
#   userland/SecurityInterface/build.sh
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/SecurityInterface"
OBJC_ARC= CFLAGS="-fno-objc-arc -Wno-incomplete-implementation -Wno-objc-property-implementation -Wno-deprecated-declarations -Wno-deprecated-implementations -Wno-objc-designated-initializers -Wno-objc-method-access -I${FINCH_ROOT}/userland" \
    "${FINCH_ROOT}/tools/build-small-framework.sh" \
    /System/Library/Frameworks/SecurityInterface.framework/Versions/A/SecurityInterface \
    55210.100.6 1 com.apple.SecurityInterface 1.0 \
    "${HERE}/SecurityInterface.m" -- -framework Foundation -framework AppKit -framework Security \
    -Wl,-reexport_framework,SecurityFoundation
