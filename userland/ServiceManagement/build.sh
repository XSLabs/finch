#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# ServiceManagement.framework: Finch's. Login items and agents as the user's launchd
# jobs (ServiceManagement.m); SMConstants.m has Apple's values.
#   userland/ServiceManagement/build.sh -> build/root/System/Library/Frameworks/ServiceManagement.framework
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/ServiceManagement"
OBJC_ARC=1 CFLAGS="-Wno-incomplete-implementation -Wno-objc-designated-initializers" "${FINCH_ROOT}/tools/build-small-framework.sh" \
    /System/Library/Frameworks/ServiceManagement.framework/Versions/A/ServiceManagement 3102.100.102 1 com.apple.xpc.ServiceManagement 1.0 \
    "${HERE}/SMConstants.m" "${HERE}/ServiceManagement.m" -- -framework Foundation -framework Security
