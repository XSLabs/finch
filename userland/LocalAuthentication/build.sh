#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# LocalAuthentication.framework: Finch's. No biometrics or prompts yet, so policies
# fail as on a Mac without them (LocalAuthentication.m); LAConstants.m has Apple's values.
#   userland/LocalAuthentication/build.sh -> build/root/System/Library/Frameworks/LocalAuthentication.framework
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/LocalAuthentication"
OBJC_ARC=1 CFLAGS="-Wno-incomplete-implementation -Wno-objc-designated-initializers" "${FINCH_ROOT}/tools/build-small-framework.sh" \
    /System/Library/Frameworks/LocalAuthentication.framework/Versions/A/LocalAuthentication 2005.100.186 1 com.apple.LocalAuthentication 1.0 \
    "${HERE}/LAConstants.m" "${HERE}/LocalAuthentication.m" -- -framework Foundation
