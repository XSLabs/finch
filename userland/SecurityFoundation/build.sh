#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# SecurityFoundation.framework: Finch's, over its Security (SecurityFoundation.m).
#   userland/SecurityFoundation/build.sh -> build/root/System/Library/Frameworks/SecurityFoundation.framework
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
exec "${FINCH_ROOT}/tools/build-small-framework.sh" \
    /System/Library/Frameworks/SecurityFoundation.framework/Versions/A/SecurityFoundation 1 1 com.apple.securityfoundation 1.0 \
    "${FINCH_ROOT}/userland/SecurityFoundation/SecurityFoundation.m" -- -framework Foundation -framework Security
