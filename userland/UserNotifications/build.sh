#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# UserNotifications.framework: Finch's. Local notifications scheduled in the app and
# delivered to its delegate (UserNotifications.m); UNConstants.m has Apple's values.
#   userland/UserNotifications/build.sh -> build/root/System/Library/Frameworks/UserNotifications.framework
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/UserNotifications"
OBJC_ARC=1 "${FINCH_ROOT}/tools/build-small-framework.sh" \
    /System/Library/Frameworks/UserNotifications.framework/Versions/A/UserNotifications 1 1 com.apple.UserNotifications 1.0 \
    "${HERE}/UNConstants.m" "${HERE}/UserNotifications.m" -- -framework Foundation
