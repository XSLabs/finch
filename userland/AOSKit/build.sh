#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# AOSKit.framework (private), Finch's own: iCloud account calls, with no account (AOSKit.c).
#   userland/AOSKit/build.sh -> build/root/System/Library/PrivateFrameworks/AOSKit.framework
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
"${FINCH_ROOT}/tools/build-small-framework.sh" \
    /System/Library/PrivateFrameworks/AOSKit.framework/Versions/A/AOSKit 282 1 com.apple.AOSKit 1.0 \
    "${FINCH_ROOT}/userland/AOSKit/AOSKit.c" -- -framework CoreFoundation
