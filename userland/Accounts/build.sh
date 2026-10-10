#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Accounts.framework: Finch's. No Internet accounts yet, so the store answers as a Mac
# with none (Accounts.m); ACConstants.m has Apple's values.
#   userland/Accounts/build.sh -> build/root/System/Library/Frameworks/Accounts.framework
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/Accounts"
OBJC_ARC=1 CFLAGS="-Wno-incomplete-implementation -Wno-objc-designated-initializers -Wno-deprecated-declarations -Wno-deprecated-implementations" \
    "${FINCH_ROOT}/tools/build-small-framework.sh" \
    /System/Library/Frameworks/Accounts.framework/Versions/A/Accounts 1.0.0 1 com.apple.Accounts 113 \
    "${HERE}/ACConstants.m" "${HERE}/Accounts.m" -- -framework Foundation
