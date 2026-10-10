#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# StoreKit.framework: Finch's. No App Store: payments not allowed, requests fail as
# offline (StoreKit.m); SKConstants.m has Apple's values.
#   userland/StoreKit/build.sh -> build/root/System/Library/Frameworks/StoreKit.framework
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/StoreKit"
OBJC_ARC=1 CFLAGS="-Wno-incomplete-implementation -Wno-objc-designated-initializers -Wno-deprecated-implementations" \
"${FINCH_ROOT}/tools/build-small-framework.sh" \
    /System/Library/Frameworks/StoreKit.framework/Versions/A/StoreKit 379 1 com.apple.StoreKit 1.0 \
    "${HERE}/SKConstants.m" "${HERE}/StoreKit.m" -- -framework Foundation
