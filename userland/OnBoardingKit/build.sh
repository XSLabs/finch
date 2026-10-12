#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# OnBoardingKit.framework (private), the AppKit side, Finch's own: welcome and privacy
# screens (OnBoardingKit.m).
#   userland/OnBoardingKit/build.sh -> build/root/System/Library/PrivateFrameworks/OnBoardingKit.framework
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/OnBoardingKit"
OBJC_ARC=1 "${FINCH_ROOT}/tools/build-small-framework.sh" \
    /System/Library/PrivateFrameworks/OnBoardingKit.framework/Versions/A/OnBoardingKit 1 1 com.apple.onboardingkit 1.0 \
    "${HERE}/OnBoardingKit.m" -- -framework AppKit -framework Foundation
