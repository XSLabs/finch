#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# OSAnalytics.framework (private), Finch's own: diagnostic reports (OSALog.m).
#   userland/OSAnalytics/build.sh -> build/root/System/Library/PrivateFrameworks/OSAnalytics.framework
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/OSAnalytics"
OBJC_ARC=1 "${FINCH_ROOT}/tools/build-small-framework.sh" \
    /System/Library/PrivateFrameworks/OSAnalytics.framework/Versions/A/OSAnalytics 1 1 com.apple.OSAnalytics 1.0 \
    "${HERE}/OSALog.m" -- -framework Foundation
